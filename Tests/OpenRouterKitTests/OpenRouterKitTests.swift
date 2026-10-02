import Foundation
import Testing
@testable import OpenRouterKit

@Test func streamsTokensAndFinishes() async throws {
    let mock = MockTransport(streams: [[
        try sse(["choices": [["delta": ["content": "Hel"]]]]),
        try sse(["choices": [["delta": ["content": "lo"]]]]),
        try sse(["choices": [["delta": [:], "finish_reason": "stop"]]]),
        "data: [DONE]",
    ]])
    let client = OpenRouterClient(apiKey: "k", transport: mock)
    var text = ""
    var finishedText: String?
    for try await event in client.stream(ORChatRequest(model: "m", messages: [ORMessage(role: .user, content: "hi")])) {
        switch event {
        case .token(let t): text += t
        case .finished(_, let message): finishedText = message.content
        default: break
        }
    }
    #expect(text == "Hello")
    #expect(finishedText == "Hello")
}

@Test func assemblesStreamedToolCallThenRunsIt() async throws {
    let mock = MockTransport(streams: [
        // Round 1: the model streams a tool call in fragments.
        [
            try sse(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "echo", "arguments": "{\"text\":"]]]]]]]),
            try sse(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "\"hi\"}"]]]]]]]),
            try sse(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]),
            "data: [DONE]",
        ],
        // Round 2: after the tool result, a plain reply.
        [
            try sse(["choices": [["delta": ["content": "done"]]]]),
            try sse(["choices": [["delta": [:], "finish_reason": "stop"]]]),
            "data: [DONE]",
        ],
    ])
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m", tools: [EchoTool()])
    let recorder = Recorder()
    try await agent.send("please echo") { await recorder.add($0) }
    var calls: [String] = []
    var results: [String] = []
    var texts: [String] = []
    for event in await recorder.events {
        switch event {
        case .toolCall(let name, let args, let id): calls.append("\(id) \(name):\(args)")
        case .toolResult(let name, let output, let id): results.append("\(id) \(name):\(output)")
        case .message(let text): texts.append(text)
        default: break
        }
    }
    #expect(calls == ["call_1 echo:{\"text\":\"hi\"}"])
    #expect(results == ["call_1 echo:hi"])
    #expect(texts == ["done"])
    // The conversation carries the user's message, the assistant's tool
    // call, the tool's result, and the reply.
    let call = ORToolCall(id: "call_1", function: .init(name: "echo", arguments: "{\"text\":\"hi\"}"))
    #expect(await agent.messages == [
        ORMessage(role: .user, content: "please echo"),
        ORMessage(role: .assistant, toolCalls: [call]),
        ORMessage(role: .tool, content: "hi", toolCallID: "call_1", name: "echo"),
        ORMessage(role: .assistant, content: "done"),
    ])
    // The second completion was asked with the tool's result in hand.
    let second = try #require(await mock.sentBodies.last)
    let root = try #require(try JSONSerialization.jsonObject(with: second) as? [String: Any])
    let sent = try #require(root["messages"] as? [[String: Any]])
    #expect(sent.map { $0["role"] as? String } == ["user", "assistant", "tool"])
    #expect(sent.last?["tool_call_id"] as? String == "call_1")
}

@Test func requestBodyCarriesToolsAndMessages() async throws {
    let mock = MockTransport(streams: [[try sse(["choices": [["delta": ["content": "ok"], "finish_reason": "stop"]]]), "data: [DONE]"]])
    let client = OpenRouterClient(apiKey: "k", transport: mock)
    let agent = ORAgent(client: client, model: "anthropic/claude", tools: [EchoTool()], systemPrompt: "sys")
    try await agent.send("hello") { _ in }
    let bodies = await mock.sentBodies
    #expect(bodies.count == 1)
    let body = try #require(bodies.first)
    let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(root["model"] as? String == "anthropic/claude")
    #expect(root["stream"] as? Bool == true)
    let messages = try #require(root["messages"] as? [[String: Any]])
    #expect(messages.map { $0["role"] as? String } == ["system", "user"])
    #expect(messages.first?["content"] as? String == "sys")
    #expect(messages.last?["content"] as? String == "hello")
    let tools = try #require(root["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect((tools.first?["function"] as? [String: Any])?["name"] as? String == "echo")
}

@Test func surfacesHTTPErrors() async throws {
    let mock = MockTransport(streams: [["unauthorized"]], status: 401)
    let client = OpenRouterClient(apiKey: "bad", transport: mock)
    let error = await #expect(throws: OpenRouterError.self) {
        for try await _ in client.stream(ORChatRequest(model: "m", messages: [])) {}
    }
    #expect(error?.status == 401)
    #expect(error?.body == "unauthorized")
}

/// OpenRouter's model list is public: fetched without a key, no
/// Authorization is sent; with one, it is.
@Test func modelsWithoutAKey() async throws {
    let transport = MockTransport(dataBody: Data(#"{"data":[{"id":"b/two","name":"B: Two"},{"id":"a/one","name":"A: One"}]}"#.utf8))
    let keyless = OpenRouterClient(apiKey: "", transport: transport)
    let list = try await keyless.models()
    #expect(list.map(\.id) == ["a/one", "b/two"])
    #expect(await transport.lastAuthorization == nil)
    _ = try await OpenRouterClient(apiKey: "sk-test", transport: transport).models()
    #expect(await transport.lastAuthorization == "Bearer sk-test")
}

/// One turn at a time: a second `send` while the first is running is
/// refused, and leaves the conversation as the first turn has it.
@Test func aSecondTurnWhileOneRunsIsRefused() async throws {
    let mock = MockTransport(streams: [[try sse(["choices": [["delta": ["content": "ok"], "finish_reason": "stop"]]]), "data: [DONE]"]])
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m")
    try await agent.send("first") { event in
        guard case .started = event else { return }
        await #expect(throws: ORAgentError.turnInProgress) { try await agent.send("second") { _ in } }
    }
    #expect(await agent.history.map(\.content) == ["first", "ok"])
    // Over, the agent takes the next.
    await #expect(throws: Never.self) { try await agent.send("third") { _ in } }
}
