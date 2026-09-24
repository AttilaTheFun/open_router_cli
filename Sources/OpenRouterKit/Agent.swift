// The agentic loop over the client: a conversation that streams the
// assistant's reply, runs any tools it asks for, and goes round again
// until the model stops calling tools. Consumers inject the tools, so
// the Playground and Visor share this and bring their own.

import Foundation

/// What the agent emits as a turn runs.
public enum ORAgentEvent: Sendable {
    /// More assistant text.
    case delta(String)
    /// The model asked to run a tool.
    case toolCall(name: String, arguments: String, id: String)
    /// A tool finished; its output (what the model sees next).
    case toolResult(name: String, output: String, id: String)
    /// One assistant message finished (text). A turn may have several,
    /// with tool runs between; each is its own message.
    case message(String)
    /// One completion finished: the assistant message whole, its text and
    /// the tool calls it asked for, before any of them runs. What a
    /// consumer that shows the calls beside the words wants.
    case assistant(ORMessage)
    /// The turn is done — the model replied without calling a tool.
    case done
    /// The context so far, when reported.
    case usage(prompt: Int, completion: Int)
}

/// A conversation with a model and a set of tools. Not an actor: callers
/// drive one turn at a time and hold their own concurrency.
public final class ORAgent: @unchecked Sendable {
    public let client: OpenRouterClient
    public var model: String
    public var temperature: Double?
    /// The reasoning effort asked of the model, when one is.
    public var reasoningEffort: String?
    private let tools: [any ORTool]
    private let toolsByName: [String: any ORTool]
    /// The whole conversation, growing with each turn; the source of
    /// truth a consumer can read or persist.
    public private(set) var messages: [ORMessage]
    /// How many tool rounds a single turn may take before it gives up.
    public var maxRounds = 24

    public init(client: OpenRouterClient, model: String, tools: [any ORTool] = [],
                systemPrompt: String? = nil, temperature: Double? = nil, reasoningEffort: String? = nil) {
        self.client = client
        self.model = model
        self.tools = tools
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
        toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        messages = systemPrompt.map { [ORMessage(role: .system, content: $0)] } ?? []
    }

    /// Adds any messages already had (resuming a conversation).
    public func load(_ history: [ORMessage]) { messages.append(contentsOf: history) }

    /// The conversation without the system prompt: what a session on
    /// disk keeps, and what `load` takes back.
    public var history: [ORMessage] { messages.filter { $0.role != .system } }

    /// Runs a user turn to completion, streaming events. Appends every
    /// message (user, assistant, tool results) to `messages` as it goes.
    public func send(_ userText: String) -> AsyncThrowingStream<ORAgentEvent, Error> {
        messages.append(ORMessage(role: .user, content: userText))
        return AsyncThrowingStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ continuation: AsyncThrowingStream<ORAgentEvent, Error>.Continuation) async {
        do {
            for _ in 0..<maxRounds {
                if Task.isCancelled { continuation.finish(); return }
                let request = ORChatRequest(model: model, messages: messages, tools: tools, temperature: temperature,
                                            reasoningEffort: reasoningEffort)
                var finished: ORMessage?
                for try await event in client.stream(request) {
                    switch event {
                    case .token(let text): continuation.yield(.delta(text))
                    case .usage(let prompt, let completion): continuation.yield(.usage(prompt: prompt, completion: completion))
                    case .toolCall: break // gathered into the finished message
                    case .finished(_, let message): finished = message
                    }
                }
                guard let message = finished else { continuation.finish(); return }
                messages.append(message)
                continuation.yield(.assistant(message))
                if let text = message.content, !text.isEmpty { continuation.yield(.message(text)) }
                guard let calls = message.toolCalls, !calls.isEmpty else {
                    continuation.yield(.done)
                    continuation.finish()
                    return
                }
                for call in calls {
                    continuation.yield(.toolCall(name: call.function.name, arguments: call.function.arguments, id: call.id))
                    let output: String
                    if let tool = toolsByName[call.function.name] {
                        do { output = try await tool.call(arguments: call.function.arguments) }
                        catch { output = "Error: \(error.localizedDescription)" }
                    } else {
                        output = "Error: no tool named \(call.function.name)"
                    }
                    continuation.yield(.toolResult(name: call.function.name, output: output, id: call.id))
                    messages.append(ORMessage(role: .tool, content: output, toolCallID: call.id, name: call.function.name))
                }
            }
            continuation.yield(.done)
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
