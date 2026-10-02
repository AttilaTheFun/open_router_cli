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

    init(streams: [[String]], status: Int = 200, key: String = "k", streamOut: Bool = true) throws {
        let mock = MockTransport(streams: streams, status: status)
        self.mock = mock
        cwd = try scratch()
        store = ORSessionStore(directory: try scratch().appendingPathComponent("sessions"))
        conversation = try Conversation(resume: nil, sessionID: nil, cwd: cwd.path, model: "m", effort: nil, store: store,
                                        makeClient: { OpenRouterClient(apiKey: key, transport: mock) })
        runner = HeadlessRunner(conversation: conversation, streamOut: streamOut,
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
    #expect(lines[0]["result"] as? String == "OpenRouter 502: upstream is down")
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

/// A session id from the command line that is not a file name is refused
/// when the conversation is opened, whether to resume or to start.
@Test func aSessionIdThatIsNotAFileNameIsRefused() throws {
    let base = try scratch()
    let store = ORSessionStore(directory: base.appendingPathComponent("sessions"))
    #expect(throws: ORSessionError.invalidID("../../etc/passwd")) {
        _ = try Conversation(resume: "../../etc/passwd", sessionID: nil, cwd: base.path, model: "m", effort: nil, store: store)
    }
    #expect(throws: ORSessionError.invalidID("../escape")) {
        _ = try Conversation(resume: nil, sessionID: "../escape", cwd: base.path, model: "m", effort: nil, store: store)
    }
    let named = try Conversation(resume: nil, sessionID: "named-by-the-host", cwd: base.path, model: "m", effort: nil, store: store)
    #expect(named.id == "named-by-the-host")
}
