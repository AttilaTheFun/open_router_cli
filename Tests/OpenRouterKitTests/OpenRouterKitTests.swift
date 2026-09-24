import Foundation
import Testing
@testable import OpenRouterKit

/// A transport that answers from canned bodies and SSE lines, so the
/// client and agent run without a network.
final class MockTransport: ORTransport, @unchecked Sendable {
    var dataBody = Data()
    var status = 200
    /// SSE line batches, one per completion the agent asks for, in order.
    var streams: [[String]] = []
    private var index = 0
    /// The request bodies seen, for assertions.
    var sentBodies: [Data] = []
    private let lock = NSLock()

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (dataBody, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let batch: [String] = lock.withLock {
            if let body = request.httpBody { sentBodies.append(body) }
            let batch = index < streams.count ? streams[index] : []
            index += 1
            return batch
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in batch { continuation.yield(line) }
            continuation.finish()
        }
        return (stream, http)
    }
}

private func sse(_ object: [String: Any]) -> String {
    "data: " + String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

@Test func streamsTokensAndFinishes() async throws {
    let mock = MockTransport()
    mock.streams = [[
        sse(["choices": [["delta": ["content": "Hel"]]]]),
        sse(["choices": [["delta": ["content": "lo"]]]]),
        sse(["choices": [["delta": [:], "finish_reason": "stop"]]]),
        "data: [DONE]",
    ]]
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
    let mock = MockTransport()
    // Round 1: the model streams a tool call in fragments.
    mock.streams = [
        [
            sse(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "echo", "arguments": "{\"text\":"]]]]]]]),
            sse(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "\"hi\"}"]]]]]]]),
            sse(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]),
            "data: [DONE]",
        ],
        // Round 2: after the tool result, a plain reply.
        [
            sse(["choices": [["delta": ["content": "done"]]]]),
            sse(["choices": [["delta": [:], "finish_reason": "stop"]]]),
            "data: [DONE]",
        ],
    ]
    let client = OpenRouterClient(apiKey: "k", transport: mock)
    let tool = EchoTool()
    let agent = ORAgent(client: client, model: "m", tools: [tool])
    var calls: [String] = []
    var results: [String] = []
    var finalText = ""
    for try await event in agent.send("please echo") {
        switch event {
        case .toolCall(let name, let args, _): calls.append("\(name):\(args)")
        case .toolResult(_, let output, _): results.append(output)
        case .message(let text): finalText = text
        default: break
        }
    }
    #expect(calls == ["echo:{\"text\":\"hi\"}"])
    #expect(results == ["hi"])
    #expect(finalText == "done")
    // The conversation carries the assistant tool call, the tool result, and the reply.
    #expect(agent.messages.contains { $0.role == .tool && $0.content == "hi" })
    #expect(agent.messages.last?.content == "done")
}

@Test func requestBodyCarriesToolsAndMessages() async throws {
    let mock = MockTransport()
    mock.streams = [[sse(["choices": [["delta": ["content": "ok"], "finish_reason": "stop"]]]), "data: [DONE]"]]
    let client = OpenRouterClient(apiKey: "k", transport: mock)
    let agent = ORAgent(client: client, model: "anthropic/claude", tools: [EchoTool()], systemPrompt: "sys")
    for try await _ in agent.send("hello") {}
    let body = try #require(mock.sentBodies.first)
    let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(root["model"] as? String == "anthropic/claude")
    #expect(root["stream"] as? Bool == true)
    let messages = try #require(root["messages"] as? [[String: Any]])
    #expect(messages.first?["role"] as? String == "system")
    #expect(messages.last?["content"] as? String == "hello")
    let tools = try #require(root["tools"] as? [[String: Any]])
    #expect((tools.first?["function"] as? [String: Any])?["name"] as? String == "echo")
}

@Test func surfacesHTTPErrors() async throws {
    let mock = MockTransport()
    mock.status = 401
    mock.streams = [["unauthorized"]]
    let client = OpenRouterClient(apiKey: "bad", transport: mock)
    await #expect(throws: OpenRouterError.self) {
        for try await _ in client.stream(ORChatRequest(model: "m", messages: [])) {}
    }
}

struct EchoTool: ORTool {
    let name = "echo"
    let toolDescription = "Echo the text back."
    let parametersJSON = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"
    func call(arguments: String) async throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
        return object?["text"] as? String ?? ""
    }
}
