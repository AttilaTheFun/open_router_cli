import Foundation
import Testing
@testable import OpenRouterKit
import TestSupport

// MARK: Sessions

@Test func sessionRoundTripsAndListsNewestFirst() throws {
    let store = ORSessionStore(directory: try scratch().appendingPathComponent("sessions"))
    let older = ORSession(cwd: "/tmp/a", model: "m", messages: [ORMessage(role: .user, content: "first question\nmore")])
    try store.save(older)
    let newer = ORSession(cwd: "/tmp/b", model: "m", messages: [ORMessage(role: .user, content: "second")])
    try store.save(newer)
    let loaded = try store.load(id: older.id)
    #expect(loaded.id == older.id)
    #expect(loaded.messages.first?.content == "first question\nmore")
    #expect(loaded.title == "first question")
    // Saving stamps `updated`, so the newer one lists first.
    #expect(store.list().map(\.id) == [newer.id, older.id])
    #expect(store.list(cwd: "/tmp/a").map(\.id) == [older.id])
    #expect(try store.exists(id: newer.id))
    #expect(try !store.exists(id: ORSession.newID()))
}

@Test func theLogIsOnlyAppendedTo() throws {
    let store = ORSessionStore(directory: try scratch().appendingPathComponent("sessions"))
    let id = ORSession.newID()
    #expect(store.loggedCount(id: id) == 0)
    try store.appendLog(id: id, [ORMessage(role: .user, content: "Add a README")], ids: [:])
    let call = ORToolCall(id: "c1", type: "function", function: .init(name: "bash", arguments: "{\"command\":\"ls\"}"))
    try store.appendLog(id: id, [ORMessage(role: .assistant, toolCalls: [call]), ORMessage(role: .tool, content: "README.md", toolCallID: "c1")], ids: [:])
    #expect(store.loggedCount(id: id) == 3)
    // A line per message, in order, each with an id of its own.
    let lines = try String(contentsOf: store.logURL(for: id), encoding: .utf8).split(separator: "\n")
    let decoded = try lines.map { try JSONDecoder().decode(ORLogLine.self, from: Data($0.utf8)) }
    #expect(decoded.map(\.message.role) == [.user, .assistant, .tool])
    #expect(Set(decoded.map(\.id)).count == 3)
    #expect(decoded[1].message.toolCalls?.first?.function.name == "bash")
}

/// A line's id is the one given for its message, where one is; a line
/// with none given gets one of its own.
@Test func aLogLineTakesTheIdGivenForItsMessage() throws {
    let store = ORSessionStore(directory: try scratch().appendingPathComponent("sessions"))
    let id = ORSession.newID()
    let messages = [ORMessage(role: .user, content: "hi"), ORMessage(role: .assistant, content: "hello"), ORMessage(role: .user, content: "more")]
    try store.appendLog(id: id, messages, ids: [1: "msg_or_given"])
    let lines = try String(contentsOf: store.logURL(for: id), encoding: .utf8).split(separator: "\n")
    let decoded = try lines.map { try JSONDecoder().decode(ORLogLine.self, from: Data($0.utf8)) }
    #expect(decoded.map(\.message) == messages)
    #expect(decoded[1].id == "msg_or_given")
    #expect(Set(decoded.map(\.id)).count == 3)
    #expect(UUID(uuidString: decoded[0].id) != nil)
    #expect(UUID(uuidString: decoded[2].id) != nil)
}

/// A log written before lines took their messages' ids (every id a UUID)
/// is read, counted and added to as it always was.
@Test func anOlderLogIsReadAndAddedTo() throws {
    let store = ORSessionStore(directory: try scratch().appendingPathComponent("sessions"))
    let id = "older"
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    let older = """
        {"id":"3b1f0c7e-58a1-4d0e-9d0a-2f4f6f1f8a01","message":{"content":"hi","role":"user"},"timestamp":"2026-09-26T20:00:00Z"}
        {"id":"9c2e7a55-0d6b-4b53-8a3e-7a1d5c0e4b02","message":{"content":"hello","role":"assistant"},"timestamp":"2026-09-26T20:00:01Z"}

        """
    try Data(older.utf8).write(to: store.logURL(for: id))
    #expect(store.loggedCount(id: id) == 2)
    try store.appendLog(id: id, [ORMessage(role: .assistant, content: "again")], ids: [0: "msg_or_new"])
    let text = try String(contentsOf: store.logURL(for: id), encoding: .utf8)
    #expect(text.hasPrefix(older))
    let decoded = try text.split(separator: "\n").map { try JSONDecoder().decode(ORLogLine.self, from: Data($0.utf8)) }
    #expect(decoded.map(\.id) == ["3b1f0c7e-58a1-4d0e-9d0a-2f4f6f1f8a01", "9c2e7a55-0d6b-4b53-8a3e-7a1d5c0e4b02", "msg_or_new"])
    #expect(decoded.map(\.message.content) == ["hi", "hello", "again"])
}

/// The whole body of a request, as the API takes it: nothing more, and
/// what is not asked for is left out, not sent as null.
@Test func theRequestBodyIsWhatTheAPITakes() throws {
    let call = ORToolCall(id: "call_1", function: .init(name: "echo", arguments: "{\"text\":\"hi\"}"))
    let request = ORChatRequest(model: "openai/gpt-5-nano", messages: [
        ORMessage(role: .system, content: "sys"),
        ORMessage(role: .user, content: "go"),
        ORMessage(role: .assistant, toolCalls: [call]),
        ORMessage(role: .tool, content: "hi", toolCallID: "call_1", name: "echo"),
    ], tools: [EchoTool()], reasoningEffort: "low")
    let body = try JSONSerialization.jsonObject(with: try OpenRouterClient.body(request)) as? NSDictionary
    let expected: NSDictionary = [
        "model": "openai/gpt-5-nano",
        "stream": true,
        "reasoning": ["effort": "low"],
        "messages": [
            ["role": "system", "content": "sys"],
            ["role": "user", "content": "go"],
            ["role": "assistant", "tool_calls": [["id": "call_1", "type": "function", "function": ["name": "echo", "arguments": "{\"text\":\"hi\"}"]]]],
            ["role": "tool", "content": "hi", "tool_call_id": "call_1", "name": "echo"],
        ],
        "tools": [["type": "function", "function": [
            "name": "echo", "description": "Echo the text back.",
            "parameters": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]],
        ]]],
    ]
    #expect(body == expected)
    // With no tools and no effort, neither key is there.
    let plain = try JSONSerialization.jsonObject(with: try OpenRouterClient.body(ORChatRequest(model: "m", messages: []))) as? NSDictionary
    #expect(plain == ["model": "m", "stream": true, "messages": [Any]()])
}

/// A tool's schema reaches the API as it was written, whatever JSON it holds.
@Test func aToolsSchemaIsSentAsWritten() throws {
    struct Tool: ORTool {
        let name = "t"
        let toolDescription = "d"
        let parametersJSON = #"{"type":"object","properties":{"n":{"type":"integer","minimum":1,"maximum":2.5,"default":null,"enum":[1,2]},"on":{"type":"boolean","default":true}},"additionalProperties":false}"#
        func call(arguments: String) async throws -> String { "" }
    }
    let body = try #require(try JSONSerialization.jsonObject(with: try OpenRouterClient.body(ORChatRequest(model: "m", messages: [], tools: [Tool()]))) as? [String: Any])
    let function = try #require(((body["tools"] as? [[String: Any]])?.first?["function"]) as? [String: Any])
    let written = try JSONSerialization.jsonObject(with: Data(Tool().parametersJSON.utf8)) as? NSDictionary
    #expect(function["parameters"] as? NSDictionary == written)
}

@Test func requestCarriesReasoningEffort() throws {
    let body = try OpenRouterClient.body(ORChatRequest(model: "m", messages: [], reasoningEffort: "high"))
    let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect((root["reasoning"] as? [String: String])?["effort"] == "high")
    let plain = try OpenRouterClient.body(ORChatRequest(model: "m", messages: []))
    let plainRoot = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
    #expect(plainRoot["reasoning"] == nil)
}

// MARK: Tools

@Test func toolsReadWriteEditAndList() async throws {
    let root = try scratch()
    let tools = CodingTools.standard(cwd: root.path)
    #expect(tools.map(\.name) == ["bash", "read_file", "write_file", "edit_file", "list_directory"])
    func call(_ name: String, _ arguments: String) async throws -> String {
        try await #require(tools.first { $0.name == name }).call(arguments: arguments)
    }
    #expect(try await call("list_directory", "{}") == "(empty)")
    let wrote = try await call("write_file", "{\"path\":\"src/a.txt\",\"content\":\"one\\ntwo\\nthree\"}")
    #expect(wrote.hasPrefix("wrote 13 bytes to "))
    #expect(try await call("read_file", "{\"path\":\"src/a.txt\",\"offset\":2,\"limit\":1}") == "2\ttwo\n… (1 more lines)\n")
    _ = try await call("edit_file", "{\"path\":\"src/a.txt\",\"old_string\":\"two\",\"new_string\":\"2\"}")
    #expect(try String(contentsOf: root.appendingPathComponent("src/a.txt"), encoding: .utf8) == "one\n2\nthree")
    #expect(try await call("list_directory", "{}") == "src/")
    #expect(try await call("list_directory", "{\"path\":\"src\"}") == "a.txt")
    #expect(try await call("bash", "{\"command\":\"cat src/a.txt; exit 3\"}") == "one\n2\nthree\n[exit 3]")
}

// MARK: Stream-json

@Test func parsesUserTurnsAndInterrupts() {
    let blocks = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"},{\"type\":\"text\",\"text\":\"there\"}]}}"
    #expect(StreamJSON.parse(blocks) == .user("hello\nthere"))
    #expect(StreamJSON.parse("{\"type\":\"user\",\"message\":{\"content\":\"plain\"}}") == .user("plain"))
    #expect(StreamJSON.parse("{\"type\":\"control_request\",\"request_id\":\"int-1\",\"request\":{\"subtype\":\"interrupt\"}}") == .interrupt(requestID: "int-1"))
    // Any other control request is one too, to be answered.
    #expect(StreamJSON.parse("{\"type\":\"control_request\",\"request_id\":\"r-2\",\"request\":{\"subtype\":\"set_model\",\"model\":\"x\"}}")
        == .control(requestID: "r-2", subtype: "set_model"))
    // A message with no text in it.
    #expect(StreamJSON.parse("{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"image\",\"source\":{}}]}}") == .user(""))
    #expect(StreamJSON.parse("{\"type\":\"user\"}") == nil)
    #expect(StreamJSON.parse("{\"type\":\"other\"}") == nil)
    #expect(StreamJSON.parse("not json") == nil)
}

@Test func controlRequestsAreAnsweredInClaudeCodesShape() throws {
    func response(_ line: String) throws -> [String: String] {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(root["type"] as? String == "control_response")
        return try #require(root["response"] as? [String: String])
    }
    #expect(try response(StreamJSON.controlResponse(requestID: "int-1")) == ["request_id": "int-1", "subtype": "success"])
    #expect(try response(StreamJSON.controlError(requestID: "r-2", error: "no")) == ["request_id": "r-2", "subtype": "error", "error": "no"])
}

@Test func assistantLineCarriesTextAndToolUseBlocks() throws {
    let message = ORMessage(role: .assistant, content: "Let me look.",
                            toolCalls: [ORToolCall(id: "call_1", function: .init(name: "bash", arguments: "{\"command\":\"ls\"}"))])
    let line = StreamJSON.assistant(id: "msg_1", model: "m", message: message, usage: (prompt: 10, completion: 2))
    let root = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(root["type"] as? String == "assistant")
    let body = try #require(root["message"] as? [String: Any])
    #expect(body["id"] as? String == "msg_1")
    #expect((body["usage"] as? [String: Int])?["input_tokens"] == 10)
    let content = try #require(body["content"] as? [[String: Any]])
    #expect(content.count == 2)
    #expect(content[0]["type"] as? String == "text")
    #expect(content[1]["type"] as? String == "tool_use")
    #expect(content[1]["id"] as? String == "call_1")
    #expect((content[1]["input"] as? [String: String])?["command"] == "ls")

    let result = StreamJSON.toolResult(callID: "call_1", output: "a\nb", isError: false)
    let resultRoot = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    #expect(resultRoot["type"] as? String == "user")
    #expect(resultRoot["uuid"] is String)
    let block = try #require(((resultRoot["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first)
    #expect(block["tool_use_id"] as? String == "call_1")
    #expect(block["content"] as? String == "a\nb")

    // A failed tool's result says so.
    let failed = StreamJSON.toolResult(callID: "call_2", output: "Error: no", isError: true)
    let failedRoot = try #require(try JSONSerialization.jsonObject(with: Data(failed.utf8)) as? [String: Any])
    let failedBlock = try #require(((failedRoot["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first)
    #expect(failedBlock["is_error"] as? Bool == true)
    #expect(block["is_error"] == nil)

    // Arguments that are not a JSON object are still shown: as the text they were.
    let odd = ORMessage(role: .assistant, toolCalls: [ORToolCall(id: "call_3", function: .init(name: "bash", arguments: "{\"command\": \"ls"))])
    let oddRoot = try #require(try JSONSerialization.jsonObject(with: Data(StreamJSON.assistant(id: "msg_2", model: "m", message: odd, usage: nil).utf8)) as? [String: Any])
    let oddBody = try #require(oddRoot["message"] as? [String: Any])
    #expect(oddBody["usage"] == nil)
    let oddContent = try #require(oddBody["content"] as? [[String: Any]])
    #expect(oddContent.count == 1)
    #expect(oddContent[0]["input"] as? [String: String] == ["input": "{\"command\": \"ls"])

    let done = StreamJSON.result(.success, text: "ok", sessionID: "s")
    let doneRoot = try #require(try JSONSerialization.jsonObject(with: Data(done.utf8)) as? [String: Any])
    #expect(doneRoot["is_error"] as? Bool == false)
    #expect(doneRoot["session_id"] as? String == "s")
}

@Test func agentAnnouncesTheWholeAssistantMessageBeforeRunningTools() async throws {
    let mock = MockTransport(streams: [
        [
            try sse(["choices": [["delta": ["content": "Looking. "]]]]),
            try sse(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "echo", "arguments": "{\"text\":\"hi\"}"]]]]]]]),
            try sse(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]),
            "data: [DONE]",
        ],
        [try sse(["choices": [["delta": ["content": "done"], "finish_reason": "stop"]]]), "data: [DONE]"],
    ])
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m", tools: [EchoTool()])
    let recorder = Recorder<ORAgentEvent>()
    try await agent.send("go") { await recorder.add($0) }
    let order: [String] = await recorder.events.compactMap { event in
        switch event {
        case .started: "started"
        case .assistant(let message, _): "assistant:\(message.content ?? "")/\(message.toolCalls?.count ?? 0)"
        case .toolCall(let name, _, _): "call:" + name
        case .toolResult(let name, _, _, _): "result:" + name
        case .delta, .usage: nil
        }
    }
    #expect(order == ["started", "assistant:Looking. /1", "call:echo", "result:echo", "assistant:done/0"])
    #expect(await agent.history.map(\.role) == [.user, .assistant, .tool, .assistant])
}

/// Each assistant message has an id of its own: its deltas carry it, and
/// the finished message has the same one.
@Test func aMessagesDeltasCarryTheIdItFinishesWith() async throws {
    let mock = MockTransport(streams: [
        [
            try sse(["choices": [["delta": ["content": "Look"]]]]),
            try sse(["choices": [["delta": ["content": "ing."]]]]),
            try sse(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "echo", "arguments": "{}"]]]]]]]),
            try sse(["choices": [["delta": [String: Any](), "finish_reason": "tool_calls"]]]),
            "data: [DONE]",
        ],
        try reply("done"),
        try toolCalls([("call_2", "echo", [:])]),
        try reply("really done"),
    ])
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m", tools: [EchoTool()])
    let recorder = Recorder<ORAgentEvent>()
    try await agent.send("go") { await recorder.add($0) }
    try await agent.send("again") { await recorder.add($0) }
    // Each message's ids, in the order its events came: deltas, then the message whole.
    var ids: [[String]] = [[]]
    for event in await recorder.events {
        switch event {
        case .delta(_, let id): ids[ids.count - 1].append(id)
        case .assistant(_, let id):
            ids[ids.count - 1].append(id)
            ids.append([])
        case .started, .toolCall, .toolResult, .usage: break
        }
    }
    ids.removeLast()
    // Two deltas and the message; one delta and the message; a message
    // with no text, so no deltas; one delta and the message.
    #expect(ids.map(\.count) == [3, 2, 1, 2])
    let each = ids.map { Set($0) }
    #expect(each.allSatisfy { $0.count == 1 })
    let all = each.flatMap { $0 }
    #expect(Set(all).count == 4)
    #expect(all.allSatisfy { $0.hasPrefix("msg_or_") && $0.count == 39 })
}

/// Resuming: the history given at the start is in the conversation, after
/// the system prompt, and `history` gives it back without the prompt.
@Test func agentStartsFromAHistory() async throws {
    let mock = MockTransport(streams: [[try sse(["choices": [["delta": ["content": "again"], "finish_reason": "stop"]]]), "data: [DONE]"]])
    let earlier = [ORMessage(role: .user, content: "before"), ORMessage(role: .assistant, content: "yes")]
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m", systemPrompt: "sys", history: earlier)
    #expect(await agent.history == earlier)
    try await agent.send("and now") { _ in }
    #expect(await agent.messages.map(\.content) == ["sys", "before", "yes", "and now", "again"])
    #expect(await agent.history.map(\.content) == ["before", "yes", "and now", "again"])
}
