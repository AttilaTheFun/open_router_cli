import Foundation
import Testing
@testable import OpenRouterKit

private func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("openrouterkit-" + UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: Sessions

@Test func sessionRoundTripsAndListsNewestFirst() throws {
    let store = ORSessionStore(directory: scratch().appendingPathComponent("sessions"))
    var older = ORSession(cwd: "/tmp/a", model: "m", messages: [ORMessage(role: .user, content: "first question\nmore")])
    older.updated = 100
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
    #expect(store.exists(id: newer.id))
    try store.remove(id: newer.id)
    #expect(!store.exists(id: newer.id))
}

// MARK: Config

@Test func keyComesFromTheEnvironmentFirst() {
    #expect(ORConfig.resolvedKey(environment: ["OPENROUTER_API_KEY": " sk-or-a "]) == "sk-or-a")
    #expect(ORConfig.resolvedKey(environment: ["OPEN_ROUTER_API_KEY": "sk-or-b"]) == "sk-or-b")
    #expect(ORConfig.resolvedKey(environment: ["OPENROUTER_API_KEY": "sk-or-a", "OPEN_ROUTER_API_KEY": "sk-or-b"]) == "sk-or-a")
    #expect(ORConfig.keySource(environment: ["OPEN_ROUTER_API_KEY": "x"]) == "environment (OPEN_ROUTER_API_KEY)")
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
    let root = scratch()
    let tools = CodingTools.standard(cwd: root.path)
    func tool(_ name: String) -> any ORTool { tools.first { $0.name == name }! }
    _ = try await tool("write_file").call(arguments: "{\"path\":\"src/a.txt\",\"content\":\"one\\ntwo\\nthree\"}")
    let read = try await tool("read_file").call(arguments: "{\"path\":\"src/a.txt\",\"offset\":2,\"limit\":1}")
    #expect(read == "2\ttwo\n… (1 more lines)\n")
    _ = try await tool("edit_file").call(arguments: "{\"path\":\"src/a.txt\",\"old_string\":\"two\",\"new_string\":\"2\"}")
    #expect(try String(contentsOf: root.appendingPathComponent("src/a.txt"), encoding: .utf8) == "one\n2\nthree")
    await #expect(throws: (any Error).self) {
        _ = try await tool("edit_file").call(arguments: "{\"path\":\"src/a.txt\",\"old_string\":\"missing\",\"new_string\":\"x\"}")
    }
    let listed = try await tool("list_directory").call(arguments: "{}")
    #expect(listed == "src/")
    let ran = try await tool("bash").call(arguments: "{\"command\":\"echo hi; exit 3\"}")
    #expect(ran.hasPrefix("hi\n"))
    #expect(ran.hasSuffix("[exit 3]"))
}

// MARK: Stream-json

@Test func parsesUserTurnsAndInterrupts() {
    let blocks = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"},{\"type\":\"text\",\"text\":\"there\"}]}}"
    #expect(StreamJSON.parse(blocks) == .user("hello\nthere"))
    #expect(StreamJSON.parse("{\"type\":\"user\",\"message\":{\"content\":\"plain\"}}") == .user("plain"))
    #expect(StreamJSON.parse("{\"type\":\"control_request\",\"request_id\":\"int-1\",\"request\":{\"subtype\":\"interrupt\"}}") == .interrupt(requestID: "int-1"))
    #expect(StreamJSON.parse("{\"type\":\"other\"}") == nil)
    #expect(StreamJSON.parse("not json") == nil)
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

    let result = StreamJSON.toolResult(callID: "call_1", output: "a\nb")
    let resultRoot = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    #expect(resultRoot["type"] as? String == "user")
    #expect(resultRoot["uuid"] is String)
    let block = try #require(((resultRoot["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first)
    #expect(block["tool_use_id"] as? String == "call_1")
    #expect(block["content"] as? String == "a\nb")

    let done = StreamJSON.result(isError: false, text: "ok", sessionID: "s")
    let doneRoot = try #require(try JSONSerialization.jsonObject(with: Data(done.utf8)) as? [String: Any])
    #expect(doneRoot["is_error"] as? Bool == false)
    #expect(doneRoot["session_id"] as? String == "s")
}

@Test func agentAnnouncesTheWholeAssistantMessageBeforeRunningTools() async throws {
    let mock = MockTransport()
    mock.streams = [
        [
            sse(["choices": [["delta": ["content": "Looking. "]]]]),
            sse(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "echo", "arguments": "{\"text\":\"hi\"}"]]]]]]]),
            sse(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]),
            "data: [DONE]",
        ],
        [sse(["choices": [["delta": ["content": "done"], "finish_reason": "stop"]]]), "data: [DONE]"],
    ]
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m", tools: [EchoTool()])
    var order: [String] = []
    for try await event in agent.send("go") {
        switch event {
        case .assistant(let message): order.append("assistant:\(message.content ?? "")/\(message.toolCalls?.count ?? 0)")
        case .toolCall(let name, _, _): order.append("call:" + name)
        case .toolResult(let name, _, _): order.append("result:" + name)
        case .done: order.append("done")
        default: break
        }
    }
    #expect(order == ["assistant:Looking. /1", "call:echo", "result:echo", "assistant:done/0", "done"])
    #expect(agent.history.count == 4)
    #expect(agent.history.first?.role == .user)
}

private func sse(_ object: [String: Any]) -> String {
    "data: " + String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}
