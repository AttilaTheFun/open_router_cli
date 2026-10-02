// The headless runner, end to end over the mock transport: what it prints
// for a turn that finishes, fails or is interrupted, and what it leaves in
// the session on disk.

import Foundation
import Testing
import OpenRouterKit
import TestSupport
@testable import openrouter

/// A runner over a mock transport, in folders of the test's own, with
/// what it writes kept.
private struct Rig {
    let mock: MockTransport
    let store: ORSessionStore
    let conversation: Conversation
    let runner: HeadlessRunner
    let cwd: URL
    private let out = Pipe()
    private let err = Pipe()

    init(streams: [[String]], status: Int = 200, key: String = "k", streamOut: Bool = true, partialMessages: Bool = true,
         maxRounds: Int? = nil) throws {
        let mock = MockTransport(streams: streams, status: status)
        self.mock = mock
        cwd = try scratch()
        store = ORSessionStore(directory: try scratch().appendingPathComponent("sessions"))
        conversation = try Conversation(resume: nil, sessionID: nil, cwd: cwd.path, model: "m", effort: nil, maxRounds: maxRounds, store: store,
                                        makeClient: { OpenRouterClient(apiKey: key, transport: mock) })
        runner = HeadlessRunner(conversation: conversation, streamOut: streamOut, partialMessages: partialMessages,
                                output: Output(out: out.fileHandleForWriting, err: err.fileHandleForWriting))
    }

    /// Everything written to stdout and stderr; call once, when the runner is done.
    func written() throws -> (out: String, err: String) {
        try out.fileHandleForWriting.close()
        try err.fileHandleForWriting.close()
        return (String(decoding: try out.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self),
                String(decoding: try err.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self))
    }
}

/// stdout's lines as JSON objects.
private func objects(_ text: String) throws -> [[String: Any]] {
    try text.split(separator: "\n").map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
}

/// The tool_result block of a `user` line.
private func toolResult(_ line: [String: Any]) throws -> [String: Any] {
    try #require(((line["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first)
}

@Test(.timeLimit(.minutes(1))) func aFinishedTurnPrintsItsMessagesAndASuccessResult() async throws {
    let rig = try Rig(streams: [
        [try sse(["choices": [["delta": ["content": "Hel"]]]]), try sse(["choices": [["delta": ["content": "lo"]]]]),
         try sse(["choices": [["delta": [String: Any](), "finish_reason": "stop"]]]), "data: [DONE]"],
    ])
    #expect(await rig.runner.turn("hi"))
    let lines = try objects(try rig.written().out)
    #expect(lines.map { $0["type"] as? String } == ["stream_event", "stream_event", "stream_event", "assistant", "result"])
    let result = try #require(lines.last)
    #expect(result["is_error"] as? Bool == false)
    #expect(result["subtype"] as? String == "success")
    #expect(result["result"] as? String == "Hello")
    #expect(result["session_id"] as? String == rig.conversation.id)
    // The session and its log hold the turn.
    #expect(try rig.store.load(id: rig.conversation.id).messages == [ORMessage(role: .user, content: "hi"), ORMessage(role: .assistant, content: "Hello")])
    #expect(rig.store.loggedCount(id: rig.conversation.id) == 2)
}

/// An interrupt while a command runs: the command is stopped, the tool
/// after it does not run, both calls are answered, the turn ends with an
/// error result, the session is saved whole, and the next turn is taken.
@Test(.timeLimit(.minutes(1))) func anInterruptStopsTheToolsAndEndsTheTurnWithAnError() async throws {
    let rig = try Rig(streams: [
        try toolCalls([("call_1", "bash", ["command": "echo $$ > started; sleep 30"]),
                       ("call_2", "write_file", ["path": "made.txt", "content": "x"])]),
        try reply("after"),
    ])
    let started = rig.cwd.appendingPathComponent("started")
    let clock = ContinuousClock()
    let start = clock.now
    await rig.runner.enqueue("go")
    await rig.runner.enqueue("again")
    // The command says when it is running; then the interrupt.
    while (try? String(contentsOf: started, encoding: .utf8))?.hasSuffix("\n") != true {
        try await Task.sleep(for: .milliseconds(20))
    }
    await rig.runner.interrupt()
    await rig.runner.drain()
    #expect(clock.now - start < .seconds(15))

    let lines = try objects(try rig.written().out)
    #expect(lines.map { $0["type"] as? String } == ["stream_event", "assistant", "user", "user", "result",
                                                    "stream_event", "stream_event", "assistant", "result"])
    // The command was stopped, and says so; it is the tool's own answer.
    let first = try toolResult(lines[2])
    #expect(first["tool_use_id"] as? String == "call_1")
    #expect((first["content"] as? String)?.contains("(interrupted)") == true)
    #expect(first["is_error"] == nil)
    let shell = try #require(pid_t(try String(contentsOf: started, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(shell, 0) != 0)
    // The tool after it did not run, and its call is answered as an error.
    let second = try toolResult(lines[3])
    #expect(second["tool_use_id"] as? String == "call_2")
    #expect(second["content"] as? String == "Interrupted: the turn was stopped before this ran.")
    #expect(second["is_error"] as? Bool == true)
    #expect(!FileManager.default.fileExists(atPath: rig.cwd.appendingPathComponent("made.txt").path))
    // The interrupted turn's result is an error, as Claude Code's is.
    #expect(lines[4]["is_error"] as? Bool == true)
    #expect(lines[4]["subtype"] as? String == "error_during_execution")
    #expect(lines[4]["result"] as? String == "Interrupted")
    // The message queued behind it ran, and the model was sent a
    // conversation with both calls answered.
    #expect(lines[8]["is_error"] as? Bool == false)
    #expect(lines[8]["result"] as? String == "after")
    let sent = try await rig.mock.sentMessages()
    #expect(sent.count == 2)
    #expect(sent.last?.map { $0["role"] } == ["system", "user", "assistant", "tool", "tool", "user"])
    // On disk: the session and its log, with every call answered.
    let saved = try rig.store.load(id: rig.conversation.id).messages
    #expect(saved.map(\.role) == [.user, .assistant, .tool, .tool, .user, .assistant])
    #expect(saved[2...3].map(\.toolCallID) == ["call_1", "call_2"])
    #expect(rig.store.loggedCount(id: rig.conversation.id) == 6)
}

@Test(.timeLimit(.minutes(1))) func aFailedTurnPrintsAnErrorResult() async throws {
    let rig = try Rig(streams: [["upstream is down"]], status: 502)
    #expect(await rig.runner.turn("hi") == false)
    let lines = try objects(try rig.written().out)
    #expect(lines.count == 1)
    #expect(lines[0]["type"] as? String == "result")
    #expect(lines[0]["is_error"] as? Bool == true)
    #expect(lines[0]["subtype"] as? String == "error_during_execution")
    #expect(lines[0]["result"] as? String == "OpenRouter 502: upstream is down")
    #expect(lines[0]["session_id"] as? String == rig.conversation.id)
    // The user's message is kept: the conversation can be carried on.
    #expect(try rig.store.load(id: rig.conversation.id).messages == [ORMessage(role: .user, content: "hi")])
}

@Test(.timeLimit(.minutes(1))) func aTurnWithNoKeyFailsWithoutAskingTheModel() async throws {
    let rig = try Rig(streams: [try reply("unasked")], key: "")
    #expect(await rig.runner.turn("hi") == false)
    let lines = try objects(try rig.written().out)
    #expect(lines.count == 1)
    #expect(lines[0]["is_error"] as? Bool == true)
    #expect((lines[0]["result"] as? String)?.hasPrefix("No OpenRouter API key.") == true)
    #expect(await rig.mock.sentBodies.isEmpty)
}

/// Text out: the reply on stdout, a failure on stderr.
@Test(.timeLimit(.minutes(1))) func textModePrintsTheReplyOrTheFailure() async throws {
    let fine = try Rig(streams: [try reply("plain answer")], streamOut: false)
    #expect(await fine.runner.turn("hi"))
    let printed = try fine.written()
    #expect(printed.out == "plain answer\n")
    #expect(printed.err == "")

    let broken = try Rig(streams: [["no"]], status: 500, streamOut: false)
    #expect(await broken.runner.turn("hi") == false)
    let failed = try broken.written()
    #expect(failed.out == "")
    #expect(failed.err == "OpenRouter 500: no\n")
}

/// A reply that never finished, and one cut off at the output limit, end
/// the turn with an error result that says so, not with a success.
@Test(.timeLimit(.minutes(1))) func aCutOffReplyEndsTheTurnWithAnError() async throws {
    let rig = try Rig(streams: [
        [try sse(["choices": [["delta": ["content": "Half an ans"]]]])],
        [try sse(["choices": [["delta": ["content": "As far as it got"]]]]),
         try sse(["choices": [["delta": [String: Any](), "finish_reason": "length"]]]), "data: [DONE]"],
    ])
    #expect(await rig.runner.turn("one") == false)
    #expect(await rig.runner.turn("two") == false)
    let lines = try objects(try rig.written().out)
    // The first: its deltas, and the error. The second: its text as a
    // message too, since the model did write it, and the error.
    #expect(lines.map { $0["type"] as? String } == ["stream_event", "stream_event", "result",
                                                    "stream_event", "stream_event", "assistant", "result"])
    #expect(lines[2]["is_error"] as? Bool == true)
    #expect(lines[2]["result"] as? String == "The reply was cut off: the stream ended before the model finished.")
    #expect(lines[6]["is_error"] as? Bool == true)
    #expect(lines[6]["result"] as? String == "The reply was cut off: the model reached its output limit.")
    #expect(try rig.store.load(id: rig.conversation.id).messages.map(\.content) == ["one", "two", "As far as it got"])
}

/// A conversation over a store, that never reaches the network or the
/// real configuration.
private func conversation(resume: String? = nil, sessionID: String? = nil, cwd: String? = nil, model: String? = "m", store: ORSessionStore,
                          streams: [[String]] = []) throws -> Conversation {
    let mock = MockTransport(streams: streams)
    return try Conversation(resume: resume, sessionID: sessionID, cwd: cwd, model: model, effort: nil, maxRounds: nil, store: store,
                            makeClient: { OpenRouterClient(apiKey: "k", transport: mock) })
}

/// A session id from the command line that is not a file name is refused
/// when the conversation is opened, whether to resume or to start.
@Test func aSessionIdThatIsNotAFileNameIsRefused() throws {
    let base = try scratch()
    let store = ORSessionStore(directory: base.appendingPathComponent("sessions"))
    #expect(throws: ORSessionError.invalidID("../../etc/passwd")) { _ = try conversation(resume: "../../etc/passwd", store: store) }
    #expect(throws: ORSessionError.invalidID("../escape")) { _ = try conversation(sessionID: "../escape", store: store) }
    #expect(throws: ORSessionError.invalidID("")) { _ = try conversation(resume: "", store: store) }
    #expect(try conversation(sessionID: "named-by-the-host", store: store).id == "named-by-the-host")
}

/// `--session-id` names a new session. Given the id of one that exists it
/// is refused, and the session is left as it was — not replaced by an
/// empty one.
@Test(.timeLimit(.minutes(1))) func aNewSessionCannotTakeTheIdOfAnExistingOne() async throws {
    let rig = try Rig(streams: [try reply("kept")])
    #expect(await rig.runner.turn("remember this"))
    let before = try Data(contentsOf: try rig.store.url(for: rig.conversation.id))
    let error = #expect(throws: ORSessionError.self) { _ = try conversation(sessionID: rig.conversation.id, store: rig.store) }
    #expect(error == .alreadyExists(rig.conversation.id))
    #expect(error?.errorDescription == "There is already a session \(rig.conversation.id); carry it on with --resume \(rig.conversation.id).")
    #expect(try Data(contentsOf: try rig.store.url(for: rig.conversation.id)) == before)
    #expect(try rig.store.load(id: rig.conversation.id).messages.map(\.content) == ["remember this", "kept"])
}

/// A resumed session works in the folder it was working in, wherever it
/// is resumed from, unless another is chosen, which it then keeps.
@Test(.timeLimit(.minutes(1))) func aResumedSessionWorksInItsOwnFolder() async throws {
    let rig = try Rig(streams: [try reply("one")])
    #expect(await rig.runner.turn("first"))
    let id = rig.conversation.id
    // Not the process's current folder: the session's.
    let resumed = try conversation(resume: id, store: rig.store)
    #expect(resumed.cwd == rig.cwd.path)
    #expect(resumed.cwd != FileManager.default.currentDirectoryPath)

    let elsewhere = try scratch()
    let moved = try conversation(resume: id, cwd: elsewhere.path, model: nil, store: rig.store, streams: [try reply("two")])
    #expect(moved.cwd == elsewhere.path)
    try await moved.run("second") { _ in }
    let saved = try rig.store.load(id: id)
    #expect(saved.cwd == elsewhere.path)
    #expect(saved.model == "m")
    #expect(saved.messages.map(\.content) == ["first", "one", "second", "two"])
}

/// The folder is kept as an absolute path, whatever was typed.
@Test func aNewSessionsFolderIsAbsolute() throws {
    let store = ORSessionStore(directory: try scratch().appendingPathComponent("sessions"))
    let here = FileManager.default.currentDirectoryPath
    #expect(try conversation(store: store).cwd == here)
    #expect(try conversation(cwd: ".", store: store).cwd == here)
    #expect(try conversation(cwd: "sub/../other", store: store).cwd == here + "/other")
    #expect(try conversation(cwd: "~", store: store).cwd == NSHomeDirectory())
    #expect(try conversation(cwd: "/tmp/somewhere", store: store).cwd == "/tmp/somewhere")
}

/// A turn whose session cannot be written says so: its result is an
/// error, not a success with nothing on disk.
@Test(.timeLimit(.minutes(1))) func aTurnThatCannotBeSavedFails() async throws {
    // The sessions folder cannot be made: a file is where it would go.
    let blocked = try scratch().appendingPathComponent("sessions")
    try Data().write(to: blocked)
    let mock = MockTransport(streams: [try reply("an answer")])
    let unsaved = try Conversation(resume: nil, sessionID: nil, cwd: try scratch().path, model: "m", effort: nil, maxRounds: nil,
                                   store: ORSessionStore(directory: blocked), makeClient: { OpenRouterClient(apiKey: "k", transport: mock) })
    let out = Pipe()
    let runner = HeadlessRunner(conversation: unsaved, streamOut: true, partialMessages: false,
                                output: Output(out: out.fileHandleForWriting, err: .nullDevice))
    #expect(await runner.turn("hi") == false)
    try out.fileHandleForWriting.close()
    let lines = try objects(String(decoding: try out.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self))
    // The reply was printed, since the model did give it; then the failure.
    #expect(lines.map { $0["type"] as? String } == ["assistant", "result"])
    #expect(lines[1]["is_error"] as? Bool == true)
    #expect(lines[1]["subtype"] as? String == "error_during_execution")
    #expect((lines[1]["result"] as? String)?.hasPrefix("The session could not be saved, so what this turn added will be lost when openrouter exits: ") == true)
}

/// A log with more lines than the session has messages (left by a save
/// that failed after its append) does not stop new messages being logged.
@Test(.timeLimit(.minutes(1))) func aLogAheadOfItsSessionStillTakesNewMessages() async throws {
    let rig = try Rig(streams: [try reply("one")])
    #expect(await rig.runner.turn("first"))
    let id = rig.conversation.id
    try rig.store.appendLog(id: id, [ORMessage(role: .user, content: "lost"), ORMessage(role: .assistant, content: "lost too"),
                                     ORMessage(role: .user, content: "and this")], ids: [:])
    #expect(rig.store.loggedCount(id: id) == 5)
    let resumed = try conversation(resume: id, store: rig.store, streams: [try reply("two")])
    try await resumed.run("second") { _ in }
    let logged = try String(contentsOf: try rig.store.logURL(for: id), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(ORLogLine.self, from: Data($0.utf8)).message.content }
    #expect(logged == ["first", "one", "lost", "lost too", "and this", "second", "two"])
    #expect(try rig.store.load(id: id).messages.map(\.content) == ["first", "one", "second", "two"])
}

/// The ids of the assistant messages a run printed: `message_start`'s and
/// `assistant`'s, in the order they came.
private func streamedIDs(_ lines: [[String: Any]]) -> (started: [String], finished: [String]) {
    var started: [String] = []
    var finished: [String] = []
    for line in lines {
        if line["type"] as? String == "assistant", let id = (line["message"] as? [String: Any])?["id"] as? String { finished.append(id) }
        if let event = line["event"] as? [String: Any], event["type"] as? String == "message_start",
           let id = (event["message"] as? [String: Any])?["id"] as? String { started.append(id) }
    }
    return (started, finished)
}

private func logLines(_ rig: Rig) throws -> [ORLogLine] {
    try String(contentsOf: try rig.store.logURL(for: rig.conversation.id), encoding: .utf8)
        .split(separator: "\n").map { try JSONDecoder().decode(ORLogLine.self, from: Data($0.utf8)) }
}

/// An assistant message is in the log under the id it streamed under: a
/// host that followed the stream finds each message on record by that id.
@Test(.timeLimit(.minutes(1))) func anAssistantMessageIsLoggedUnderTheIdItStreamedUnder() async throws {
    let rig = try Rig(streams: [
        [
            try sse(["choices": [["delta": ["content": "Looking."]]]]),
            try sse(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "list_directory", "arguments": "{}"]]]]]]]),
            try sse(["choices": [["delta": [String: Any](), "finish_reason": "tool_calls"]]]),
            "data: [DONE]",
        ],
        try toolCalls([("call_2", "list_directory", [:])]),
        try reply("Nothing here."),
        try reply("Still nothing."),
    ])
    #expect(await rig.runner.turn("what is here?"))
    #expect(await rig.runner.turn("and now?"))
    let ids = streamedIDs(try objects(try rig.written().out))
    // Four assistant messages, each started and finished under one id, all different.
    #expect(ids.finished.count == 4)
    #expect(ids.started == ids.finished)
    #expect(Set(ids.finished).count == 4)

    let log = try logLines(rig)
    #expect(log.map(\.message.role) == [.user, .assistant, .tool, .assistant, .tool, .assistant, .user, .assistant])
    // The assistant lines have the streamed ids, in order.
    #expect(log.filter { $0.message.role == .assistant }.map(\.id) == ids.finished)
    // The other lines have ids of their own, and no id is used twice.
    #expect(Set(log.map(\.id)).count == log.count)
    #expect(log.filter { $0.message.role != .assistant }.allSatisfy { UUID(uuidString: $0.id) != nil })
    // A tool call is one id throughout: the call's, and its answer's.
    #expect(log[1].message.toolCalls?.map(\.id) == ["call_1"])
    #expect(log[2].message.toolCallID == "call_1")
}

/// The log's ids do not depend on stream-json being asked for: in text
/// mode an assistant message's line still has the agent's id for it.
@Test(.timeLimit(.minutes(1))) func textModeLogsAssistantMessagesUnderTheirIdsToo() async throws {
    let rig = try Rig(streams: [try reply("plain")], streamOut: false)
    #expect(await rig.runner.turn("hi"))
    let log = try logLines(rig)
    #expect(log.map(\.message.role) == [.user, .assistant])
    #expect(log[1].id.hasPrefix("msg_or_"))
    #expect(UUID(uuidString: log[0].id) != nil)
}

/// A session resumed in a new process: what the earlier run logged stays
/// as it is, and the new run's assistant message has its streamed id.
@Test(.timeLimit(.minutes(1))) func aResumedSessionKeepsItsLogAndAddsToIt() async throws {
    let first = try Rig(streams: [try reply("one")])
    #expect(await first.runner.turn("first"))
    let before = try logLines(first)

    let mock = MockTransport(streams: [try reply("two")])
    let out = Pipe()
    let resumed = try Conversation(resume: first.conversation.id, sessionID: nil, cwd: nil, model: nil, effort: nil, maxRounds: nil,
                                   store: first.store, makeClient: { OpenRouterClient(apiKey: "k", transport: mock) })
    let runner = HeadlessRunner(conversation: resumed, streamOut: true, partialMessages: true,
                                output: Output(out: out.fileHandleForWriting, err: .nullDevice))
    #expect(await runner.turn("second"))
    try out.fileHandleForWriting.close()
    let ids = streamedIDs(try objects(String(decoding: try out.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)))

    let after = try logLines(first)
    #expect(Array(after.prefix(2)) == before)
    #expect(after.map(\.message.content) == ["first", "one", "second", "two"])
    #expect(ids.finished.count == 1)
    #expect(after[3].id == ids.finished.first)
}

/// Without `--include-partial-messages` the finished messages are printed
/// and the text as it is written is not, as Claude Code does.
@Test(.timeLimit(.minutes(1))) func withoutPartialMessagesOnlyWholeMessagesArePrinted() async throws {
    let rig = try Rig(streams: [
        [try sse(["choices": [["delta": ["content": "Hel"]]]]), try sse(["choices": [["delta": ["content": "lo"]]]]),
         try sse(["choices": [["delta": [String: Any](), "finish_reason": "stop"]]]), "data: [DONE]"],
    ], partialMessages: false)
    #expect(await rig.runner.turn("hi"))
    let lines = try objects(try rig.written().out)
    #expect(lines.map { $0["type"] as? String } == ["assistant", "result"])
    let content = try #require((lines[0]["message"] as? [String: Any])?["content"] as? [[String: Any]])
    #expect(content.first?["text"] as? String == "Hello")
    // The message still has the id its log line has.
    #expect((lines[0]["message"] as? [String: Any])?["id"] as? String == (try logLines(rig))[1].id)
}

/// `--max-turns`: the turn stops after that many rounds of tool calls,
/// with the result Claude Code gives for it.
@Test(.timeLimit(.minutes(1))) func aTurnOutOfRoundsEndsWithErrorMaxTurns() async throws {
    let again = try toolCalls([("call_1", "list_directory", [:])])
    let rig = try Rig(streams: [again, again, again], maxRounds: 2)
    #expect(await rig.runner.turn("go") == false)
    let lines = try objects(try rig.written().out)
    let result = try #require(lines.last)
    #expect(result["type"] as? String == "result")
    #expect(result["subtype"] as? String == "error_max_turns")
    #expect(result["is_error"] as? Bool == true)
    #expect(result["result"] as? String == "The turn was stopped after 2 rounds of tool calls without a final answer.")
    #expect(await rig.mock.sentBodies.count == 2)
}

/// The first line says what is in effect: one permission mode, no MCP.
@Test func theInitLineSaysWhatIsInEffect() throws {
    let line = StreamJSON.systemInit(sessionID: "s", model: "m", cwd: "/tmp", tools: ["bash"])
    let root = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(root["type"] as? String == "system")
    #expect(root["subtype"] as? String == "init")
    #expect(root["session_id"] as? String == "s")
    #expect(root["model"] as? String == "m")
    #expect(root["cwd"] as? String == "/tmp")
    #expect(root["tools"] as? [String] == ["bash"])
    #expect(root["permissionMode"] as? String == "bypassPermissions")
    #expect((root["mcp_servers"] as? [Any])?.isEmpty == true)
}

/// The lines a host writes on stdin: a message is run, an interrupt and
/// any other control request are each answered, and a line that is
/// neither is passed over.
@Test(.timeLimit(.minutes(1))) func stdinLinesAreRunOrAnswered() async throws {
    let rig = try Rig(streams: [try reply("hello back")])
    await rig.runner.take(line: #"{"type":"control_request","request_id":"init-1","request":{"subtype":"initialize"}}"#)
    await rig.runner.take(line: #"{"type":"keep_alive"}"#)
    await rig.runner.take(line: "not json")
    await rig.runner.take(line: #"{"type":"control_request","request_id":"int-1","request":{"subtype":"interrupt"}}"#)
    await rig.runner.take(line: #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#)
    await rig.runner.drain()
    let lines = try objects(try rig.written().out)
    #expect(lines.map { $0["type"] as? String } == ["control_response", "control_response", "stream_event", "stream_event", "assistant", "result"])
    // A request it does not take is refused, not left unanswered.
    #expect(lines[0]["response"] as? [String: String] == ["request_id": "init-1", "subtype": "error",
                                                          "error": "openrouter does not take the control request \"initialize\""])
    // An interrupt with no turn in flight is still answered.
    #expect(lines[1]["response"] as? [String: String] == ["request_id": "int-1", "subtype": "success"])
    #expect(lines[5]["result"] as? String == "hello back")
    #expect(try await rig.mock.sentMessages().first?.last == ["role": "user", "content": "hello"])
}

/// A message with no text is not sent to the model as an empty one: its
/// turn ends at once with an error, and the next message runs.
@Test(.timeLimit(.minutes(1))) func aMessageWithNoTextIsRefused() async throws {
    let rig = try Rig(streams: [try reply("fine")])
    await rig.runner.take(line: #"{"type":"user","message":{"role":"user","content":[{"type":"image","source":{}}]}}"#)
    await rig.runner.take(line: #"{"type":"user","message":{"role":"user","content":"  \n"}}"#)
    await rig.runner.take(line: #"{"type":"user","message":{"role":"user","content":"words"}}"#)
    await rig.runner.drain()
    let lines = try objects(try rig.written().out)
    #expect(lines.map { $0["type"] as? String } == ["result", "result", "stream_event", "stream_event", "assistant", "result"])
    for refused in lines.prefix(2) {
        #expect(refused["is_error"] as? Bool == true)
        #expect(refused["result"] as? String == "The message has no text, and openrouter takes only text.")
    }
    #expect(lines[5]["is_error"] as? Bool == false)
    // Only the message with words reached the model or the session.
    #expect(await rig.mock.sentBodies.count == 1)
    #expect(try rig.store.load(id: rig.conversation.id).messages.map(\.content) == ["words", "fine"])
}

/// The tokens a completion reports go on its assistant line, and on that
/// one only; a failed tool's result line says it failed.
@Test(.timeLimit(.minutes(1))) func usageAndToolFailuresReachTheLines() async throws {
    var first = try toolCalls([("call_1", "read_file", ["path": "nowhere.txt"])])
    first.insert(try sse(["choices": [[String: Any]](), "usage": ["prompt_tokens": 120, "completion_tokens": 8]]), at: first.count - 1)
    let rig = try Rig(streams: [first, try reply("It is not there.")])
    #expect(await rig.runner.turn("read it"))
    let lines = try objects(try rig.written().out)
    #expect(lines.map { $0["type"] as? String } == ["stream_event", "assistant", "user", "stream_event", "stream_event", "assistant", "result"])
    let asked = try #require(lines[1]["message"] as? [String: Any])
    #expect(asked["usage"] as? [String: Int] == ["input_tokens": 120, "output_tokens": 8])
    #expect(asked["model"] as? String == "m")
    let answered = try #require(lines[5]["message"] as? [String: Any])
    #expect(answered["usage"] == nil)
    let result = try toolResult(lines[2])
    #expect(result["tool_use_id"] as? String == "call_1")
    #expect(result["is_error"] as? Bool == true)
    #expect((result["content"] as? String)?.hasPrefix("Error: cannot read ") == true)
}

@Test func effortsAreTheOnesOpenRouterTakes() {
    #expect(Conversation.effort("low") == "low")
    #expect(Conversation.effort("Medium") == "medium")
    #expect(Conversation.effort("HIGH") == "high")
    // Claude Code's levels above high read as high.
    #expect(Conversation.effort("xhigh") == "high")
    #expect(Conversation.effort("max") == "high")
    // Anything else is no effort at all: the model's default.
    #expect(Conversation.effort("minimal") == nil)
    #expect(Conversation.effort("") == nil)
    #expect(Conversation.effort(nil) == nil)
}
