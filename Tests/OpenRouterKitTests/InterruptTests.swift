// An interrupted turn: cancelling the task that runs it stops the reply or
// the tools, `send` throws `CancellationError`, and the conversation is
// left so that the next request is accepted — every tool call answered.

import Foundation
import Testing
@testable import OpenRouterKit
import TestSupport

/// A tool that says when it has started and then waits to be cancelled.
private struct WaitTool: ORTool {
    let name = "wait"
    let toolDescription = "Wait."
    let parametersJSON = "{\"type\":\"object\"}"
    let started: AsyncStream<Void>.Continuation
    func call(arguments: String) async throws -> String {
        started.yield()
        try await Task.sleep(for: .seconds(3600))
        return "waited"
    }
}

/// A tool that counts its runs.
private actor Counter {
    private(set) var runs = 0
    func run() { runs += 1 }
}

private struct CountTool: ORTool {
    let name = "count"
    let toolDescription = "Count."
    let parametersJSON = "{\"type\":\"object\"}"
    let counter: Counter
    func call(arguments: String) async throws -> String {
        await counter.run()
        return "counted"
    }
}

@Test(.timeLimit(.minutes(1))) func interruptStopsTheRunningToolAndRunsNoMore() async throws {
    let mock = MockTransport(streams: [
        try toolCalls([("call_1", "wait", [:]), ("call_2", "count", [:]), ("call_3", "count", [:])]),
        try reply("never asked for"),
    ])
    let (started, signal) = AsyncStream.makeStream(of: Void.self)
    let counter = Counter()
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m",
                        tools: [WaitTool(started: signal), CountTool(counter: counter)])
    let recorder = Recorder<ORAgentEvent>()
    let turn = Task { try await agent.send("go") { await recorder.add($0) } }
    for await _ in started { break }
    turn.cancel()
    await #expect(throws: CancellationError.self) { try await turn.value }

    // Nothing ran after the interrupt, and the model was not asked again.
    #expect(await counter.runs == 0)
    #expect(await mock.sentBodies.count == 1)
    // Every call has its answer, in order, directly after the message that made them.
    let history = await agent.history
    #expect(history.map(\.role) == [.user, .assistant, .tool, .tool, .tool])
    #expect(history.dropFirst(2).map(\.toolCallID) == ["call_1", "call_2", "call_3"])
    #expect(history.dropFirst(2).map(\.content) == [ORMessage.stopped, ORMessage.notRun, ORMessage.notRun])
    // And a consumer was told of each, as an error.
    let results: [String] = await recorder.events.compactMap {
        if case .toolResult(let name, let output, let id, let isError) = $0 { "\(id) \(name) \(isError) \(output)" } else { nil }
    }
    #expect(results == [
        "call_1 wait true \(ORMessage.stopped)",
        "call_2 count true \(ORMessage.notRun)",
        "call_3 count true \(ORMessage.notRun)",
    ])
}

@Test(.timeLimit(.minutes(1))) func interruptDuringTheReplyThrowsAndTheConversationGoesOn() async throws {
    let mock = MockTransport(streams: [
        [try sse(["choices": [["delta": ["content": "Hel"]]]]), MockTransport.stall],
        try reply("second answer"),
    ])
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m")
    let (deltas, signal) = AsyncStream.makeStream(of: Void.self)
    let turn = Task {
        try await agent.send("first") { event in
            if case .delta = event { signal.yield() }
        }
    }
    for await _ in deltas { break }
    turn.cancel()
    await #expect(throws: CancellationError.self) { try await turn.value }
    // The half-written reply is not kept; the user's message is.
    #expect(await agent.history == [ORMessage(role: .user, content: "first")])

    // The agent is free again, and the next turn runs.
    try await agent.send("second") { _ in }
    #expect(await agent.history.map(\.content) == ["first", "second", "second answer"])
}

/// A turn that was already cancelled when it was sent asks the model nothing.
@Test(.timeLimit(.minutes(1))) func aCancelledTaskAsksTheModelNothing() async throws {
    let mock = MockTransport(streams: [try reply("unasked")])
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m")
    // The task waits at a gate that never opens, so it is cancelled by
    // the time it sends.
    let (gate, _) = AsyncStream.makeStream(of: Void.self)
    let turn = Task {
        for await _ in gate {}
        try await agent.send("go") { _ in }
    }
    turn.cancel()
    await #expect(throws: CancellationError.self) { try await turn.value }
    #expect(await mock.sentBodies.isEmpty)
}

/// A transport whose stream, when the task reading it is cancelled,
/// throws what URLSession throws: its own error, not `CancellationError`.
private struct CancelsLikeURLSession: ORTransport {
    struct Lines: AsyncSequence, Sendable {
        typealias Element = String

        struct AsyncIterator: AsyncIteratorProtocol {
            let started: AsyncStream<Void>.Continuation

            mutating func next() async throws -> String? {
                started.yield()
                do { try await Task.sleep(for: .seconds(3600)) } catch { throw URLError(.cancelled) }
                return nil
            }
        }

        let started: AsyncStream<Void>.Continuation

        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(started: started) }
    }

    let started: AsyncStream<Void>.Continuation

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.unsupportedURL) }

    func lines(for request: URLRequest) async throws -> (any AsyncSequence<String, any Error> & Sendable, HTTPURLResponse) {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badURL)
        }
        return (Lines(started: started), response)
    }
}

/// Whatever the transport throws when it is cancelled, a cancelled
/// completion and a cancelled turn end as `CancellationError`.
@Test(.timeLimit(.minutes(1))) func aCancelledRequestIsACancellationWhateverTheTransportThrows() async throws {
    let (reading, signal) = AsyncStream.makeStream(of: Void.self)
    let client = OpenRouterClient(apiKey: "k", transport: CancelsLikeURLSession(started: signal))
    let asking = Task { try await client.complete(ORChatRequest(model: "m", messages: [])) { _ in } }
    for await _ in reading { break }
    asking.cancel()
    await #expect(throws: CancellationError.self) { _ = try await asking.value }

    let (again, second) = AsyncStream.makeStream(of: Void.self)
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: CancelsLikeURLSession(started: second)), model: "m")
    let turn = Task { try await agent.send("go") { _ in } }
    for await _ in again { break }
    turn.cancel()
    await #expect(throws: CancellationError.self) { try await turn.value }
    #expect(await agent.history == [ORMessage(role: .user, content: "go")])
}

// MARK: Conversations with a tool call left open

private let callA = ORToolCall(id: "a", function: .init(name: "bash", arguments: "{}"))
private let callB = ORToolCall(id: "b", function: .init(name: "read_file", arguments: "{}"))

private func answer(_ id: String, _ content: String, name: String? = nil) -> ORMessage {
    ORMessage(role: .tool, content: content, toolCallID: id, name: name)
}

@Test func aWellFormedConversationIsLeftAsItIs() {
    let messages = [
        ORMessage(role: .system, content: "sys"),
        ORMessage(role: .user, content: "go"),
        ORMessage(role: .assistant, content: "looking", toolCalls: [callA, callB]),
        answer("a", "one"), answer("b", "two"),
        ORMessage(role: .assistant, content: "done"),
        ORMessage(role: .user, content: "again"),
        // The same ids again: some models number their calls from the start each time.
        ORMessage(role: .assistant, toolCalls: [callA]),
        answer("a", "three"),
    ]
    #expect(ORMessage.answeringEveryToolCall(messages) == messages)
    #expect(ORMessage.answeringEveryToolCall([]) == [])
}

@Test func openToolCallsAreAnswered() {
    // Killed with the first tool done and the second running.
    let killed = [
        ORMessage(role: .user, content: "go"),
        ORMessage(role: .assistant, toolCalls: [callA, callB]),
        answer("a", "one"),
    ]
    #expect(ORMessage.answeringEveryToolCall(killed) == killed + [answer("b", ORMessage.unanswered, name: "read_file")])

    // Saved at an interrupt with no answers at all, and carried on.
    let carriedOn = [
        ORMessage(role: .user, content: "go"),
        ORMessage(role: .assistant, toolCalls: [callA, callB]),
        ORMessage(role: .user, content: "never mind"),
    ]
    #expect(ORMessage.answeringEveryToolCall(carriedOn) == [
        ORMessage(role: .user, content: "go"),
        ORMessage(role: .assistant, toolCalls: [callA, callB]),
        answer("a", ORMessage.unanswered, name: "bash"), answer("b", ORMessage.unanswered, name: "read_file"),
        ORMessage(role: .user, content: "never mind"),
    ])
}

@Test func misplacedAnswersAreMovedAndStrayOnesLeftOut() {
    // The answers landed after the next user message, out of order; one
    // answers a call nobody made.
    let messages = [
        ORMessage(role: .user, content: "go"),
        ORMessage(role: .assistant, toolCalls: [callA, callB]),
        ORMessage(role: .user, content: "and?"),
        answer("b", "two"), answer("zzz", "stray"), answer("a", "one"),
        ORMessage(role: .assistant, content: "done"),
    ]
    #expect(ORMessage.answeringEveryToolCall(messages) == [
        ORMessage(role: .user, content: "go"),
        ORMessage(role: .assistant, toolCalls: [callA, callB]),
        answer("a", "one"), answer("b", "two"),
        ORMessage(role: .user, content: "and?"),
        ORMessage(role: .assistant, content: "done"),
    ])
    // An answer before any call is a stray too.
    #expect(ORMessage.answeringEveryToolCall([answer("a", "early"), ORMessage(role: .user, content: "go")]) == [ORMessage(role: .user, content: "go")])
}

/// A session saved with a tool call open is resumed: the request the model
/// gets has the call answered, and what is on record is not rewritten.
@Test func aResumedConversationWithAnOpenCallIsSentWhole() async throws {
    let mock = MockTransport(streams: [try reply("carrying on")])
    let saved = [ORMessage(role: .user, content: "go"), ORMessage(role: .assistant, toolCalls: [callA])]
    let agent = ORAgent(client: OpenRouterClient(apiKey: "k", transport: mock), model: "m", history: saved)
    try await agent.send("still there?") { _ in }
    let sent = try #require(try await mock.sentMessages().first)
    #expect(sent.map { $0["role"] } == ["user", "assistant", "tool", "user"])
    #expect(sent[2] == ["role": "tool", "tool_call_id": "a", "name": "bash", "content": ORMessage.unanswered])
    #expect(await agent.history.map(\.role) == [.user, .assistant, .user, .assistant])
}
