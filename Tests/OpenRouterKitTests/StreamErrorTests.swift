// A reply that failed, was cut short or never finished is an error, not
// an answer: the client's stream throws, and so does the agent's turn.

import Foundation
import Testing
@testable import OpenRouterKit
import TestSupport

private func chat(_ transport: MockTransport) -> AsyncThrowingStream<ORStreamEvent, Error> {
    OpenRouterClient(apiKey: "k", transport: transport).stream(ORChatRequest(model: "m", messages: [ORMessage(role: .user, content: "hi")]))
}

/// The text of the tokens, and the finished message with its reason; throws what the stream throws.
private func collect(_ stream: AsyncThrowingStream<ORStreamEvent, Error>) async throws -> (tokens: String, reason: String?, message: ORMessage?) {
    var tokens = ""
    var reason: String?
    var message: ORMessage?
    for try await event in stream {
        switch event {
        case .token(let text): tokens += text
        case .finished(let why, let whole): (reason, message) = (why, whole)
        case .toolCall, .usage: break
        }
    }
    return (tokens, reason, message)
}

private let hello = ["choices": [["delta": ["content": "Hello"]]]]

// MARK: The client

@Test func aStreamThatEndsBeforeTheCompletionThrows() async throws {
    // The connection dropped after some text: no finish reason, no [DONE].
    let mock = MockTransport(streams: [[try sse(hello)]])
    await #expect(throws: ORStreamError.incomplete) { _ = try await collect(chat(mock)) }
    // Nothing at all came.
    await #expect(throws: ORStreamError.incomplete) { _ = try await collect(chat(MockTransport(streams: [[]]))) }
}

@Test func eitherTheFinishReasonOrDoneEndsACompletion() async throws {
    let reasonOnly = MockTransport(streams: [[try sse(hello), try sse(["choices": [["delta": [String: Any](), "finish_reason": "stop"]]])]])
    let first = try await collect(chat(reasonOnly))
    #expect(first.reason == "stop")
    #expect(first.message == ORMessage(role: .assistant, content: "Hello"))

    let doneOnly = MockTransport(streams: [[try sse(hello), "data: [DONE]"]])
    let second = try await collect(chat(doneOnly))
    #expect(second.reason == nil)
    #expect(second.message == ORMessage(role: .assistant, content: "Hello"))
}

@Test func anErrorInTheStreamThrowsIt() async throws {
    // OpenRouter's shape for a provider that fails part-way.
    let failed: [String: Any] = ["error": ["code": 502, "message": "Provider disconnected"],
                                 "choices": [["delta": ["content": ""], "finish_reason": "error"]]]
    let mock = MockTransport(streams: [[try sse(hello), try sse(failed), "data: [DONE]"]])
    let error = await #expect(throws: ORStreamError.self) { _ = try await collect(chat(mock)) }
    #expect(error == .failed(code: "502", message: "Provider disconnected"))
    #expect(error?.errorDescription == "OpenRouter failed during the reply: Provider disconnected (502)")

    // A code that is a word, and a finish reason of "error" with no error object.
    let worded = MockTransport(streams: [[try sse(["error": ["code": "rate_limited", "message": "Slow down"]])]])
    await #expect(throws: ORStreamError.failed(code: "rate_limited", message: "Slow down")) { _ = try await collect(chat(worded)) }
    let bare = MockTransport(streams: [[try sse(["choices": [["delta": [String: Any](), "finish_reason": "error"]]]), "data: [DONE]"]])
    await #expect(throws: ORStreamError.failed(code: nil, message: "the provider ended the reply with an error")) { _ = try await collect(chat(bare)) }
}

@Test func aDataLineThatIsNotACompletionThrows() async throws {
    let mock = MockTransport(streams: [[try sse(hello), "data: <html>Bad Gateway</html>", "data: [DONE]"]])
    await #expect(throws: ORStreamError.malformed("<html>Bad Gateway</html>")) { _ = try await collect(chat(mock)) }
}

@Test func commentsAndBlankLinesAreNotData() async throws {
    let mock = MockTransport(streams: [[": OPENROUTER PROCESSING", "", try sse(hello), "event: ping", ": keep-alive",
                                        try sse(["choices": [["delta": [String: Any](), "finish_reason": "stop"]]]),
                                        try sse(["choices": [[String: Any]](), "usage": ["prompt_tokens": 7, "completion_tokens": 2]]),
                                        "data: [DONE]"]])
    var usage: [Int] = []
    var text = ""
    for try await event in chat(mock) {
        switch event {
        case .usage(let prompt, let completion): usage = [prompt, completion]
        case .token(let piece): text += piece
        case .finished, .toolCall: break
        }
    }
    #expect(text == "Hello")
    #expect(usage == [7, 2])
}

/// A response that is not HTTP's has no status to call a success.
@Test func aResponseThatIsNotHTTPIsRefused() async throws {
    let file = try scratch().appendingPathComponent("models.json")
    try Data(#"{"data":[]}"#.utf8).write(to: file)
    await #expect(throws: URLError.self) { _ = try await URLSessionTransport().data(for: URLRequest(url: file)) }
    await #expect(throws: URLError.self) { _ = try await URLSessionTransport().lines(for: URLRequest(url: file)) }
}

// MARK: The agent

@Test func aTruncatedReplyFailsTheTurn() async throws {
    let mock = MockTransport(streams: [[try sse(hello)], try reply("whole")])
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m")
    let recorder = Recorder()
    await #expect(throws: ORStreamError.incomplete) { try await agent.send("hi") { await recorder.add($0) } }
    // No assistant message was announced or kept; the user's is.
    #expect(await recorder.events.contains { if case .assistant = $0 { true } else { false } } == false)
    #expect(await agent.history == [ORMessage(role: .user, content: "hi")])
    // The conversation carries on.
    try await agent.send("again") { _ in }
    #expect(await agent.history.map(\.content) == ["hi", "again", "whole"])
}

@Test func aReplyCutOffAtTheOutputLimitFailsTheTurnAndKeepsItsText() async throws {
    let mock = MockTransport(streams: [[try sse(hello), try sse(["choices": [["delta": [String: Any](), "finish_reason": "length"]]]), "data: [DONE]"]])
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m")
    let error = await #expect(throws: ORAgentError.self) { try await agent.send("hi") { _ in } }
    #expect(error == .replyCutOff(reason: "length"))
    #expect(error?.errorDescription == "The reply was cut off: the model reached its output limit.")
    #expect(await agent.history == [ORMessage(role: .user, content: "hi"), ORMessage(role: .assistant, content: "Hello")])
}

/// A reply cut off while it was writing a tool call: the call's arguments
/// are not whole, so it is neither run nor kept.
@Test func aToolCallCutOffIsNotRun() async throws {
    let mock = MockTransport(streams: [[
        try sse(["choices": [["delta": ["content": "Writing. "]]]]),
        try sse(["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "echo", "arguments": "{\"text\":\"hal"]]]]]]]),
        try sse(["choices": [["delta": [String: Any](), "finish_reason": "length"]]]),
        "data: [DONE]",
    ]])
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m", tools: [EchoTool()])
    let recorder = Recorder()
    await #expect(throws: ORAgentError.replyCutOff(reason: "length")) { try await agent.send("hi") { await recorder.add($0) } }
    #expect(await agent.history == [ORMessage(role: .user, content: "hi"), ORMessage(role: .assistant, content: "Writing. ")])
    #expect(await recorder.events.contains { if case .toolCall = $0 { true } else { false } } == false)
    #expect(await mock.sentBodies.count == 1)
}

@Test func aFilteredReplyAndAnEmptyOneFailTheTurn() async throws {
    let mock = MockTransport(streams: [
        [try sse(["choices": [["delta": [String: Any](), "finish_reason": "content_filter"]]]), "data: [DONE]"],
        [try sse(["choices": [["delta": [String: Any](), "finish_reason": "stop"]]]), "data: [DONE]"],
    ])
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m")
    await #expect(throws: ORAgentError.replyCutOff(reason: "content_filter")) { try await agent.send("one") { _ in } }
    await #expect(throws: ORAgentError.emptyReply) { try await agent.send("two") { _ in } }
    // Neither left an empty assistant message behind.
    #expect(await agent.history.map(\.role) == [.user, .user])
}

@Test func aFailureAfterAToolRanKeepsTheConversationWhole() async throws {
    let mock = MockTransport(streams: [
        try toolCalls([("call_1", "echo", ["text": "hi"])]),
        [try sse(["error": ["code": 500, "message": "Internal"]])],
    ])
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m", tools: [EchoTool()])
    await #expect(throws: ORStreamError.failed(code: "500", message: "Internal")) { try await agent.send("go") { _ in } }
    #expect(await agent.history.map(\.role) == [.user, .assistant, .tool])
}

/// A turn that uses all its rounds says so; it does not end as though the
/// model had answered.
@Test func aTurnThatRunsOutOfRoundsFails() async throws {
    let again = try toolCalls([("call_1", "echo", ["text": "hi"])])
    let mock = MockTransport(streams: [again, again, again])
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m", tools: [EchoTool()], maxRounds: 2)
    let error = await #expect(throws: ORAgentError.self) { try await agent.send("go") { _ in } }
    #expect(error == .tooManyRounds(2))
    #expect(error?.errorDescription == "The turn was stopped after 2 rounds of tool calls without a final answer.")
    // Two rounds were asked for, no more, and every call is answered.
    #expect(await mock.sentBodies.count == 2)
    #expect(await agent.history.map(\.role) == [.user, .assistant, .tool, .assistant, .tool])
}
