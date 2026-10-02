// The agentic loop over the client: a conversation that streams the
// assistant's reply, runs any tools it asks for, and goes round again
// until the model stops calling tools. Consumers inject the tools: the
// CLI brings the coding tools, a host that embeds the library its own.

import Foundation

/// What the agent reports as a turn runs.
public enum ORAgentEvent: Sendable {
    /// The turn has begun: the user's message is in the conversation.
    case started
    /// More assistant text, and the id of the message it belongs to: the
    /// one `assistant` gives when that message is whole.
    case delta(String, messageID: String)
    /// The model asked to run a tool.
    case toolCall(name: String, arguments: String, id: String)
    /// A tool call was answered: the output (what the model sees next),
    /// and whether it is an error's — the tool threw, there is no such
    /// tool, or the turn was interrupted — rather than the tool's own.
    case toolResult(name: String, output: String, id: String, isError: Bool)
    /// One completion finished: the assistant message whole, its text and
    /// the tool calls it asked for, before any of them runs. A turn may
    /// have several, with tool runs between. The id is
    /// the message's own, the agent's: its deltas carried it, and a
    /// consumer that keeps the message keeps it under it, so whoever
    /// watched the message stream finds it on record by the same name.
    case assistant(ORMessage, id: String)
    /// The context so far, when reported.
    case usage(prompt: Int, completion: Int)
}

public enum ORAgentError: LocalizedError, Equatable {
    /// Why a reply stopped before it was whole, as the API names it.
    public enum CutOff: String, Sendable {
        /// The model reached its output limit.
        case length
        case contentFilter = "content_filter"
    }

    /// `send` was called while a turn was still running.
    case turnInProgress
    /// The model stopped before its reply was whole. The text it had
    /// written is in the conversation; any tool calls, whose arguments
    /// may be cut short, are not, and were not run.
    case replyCutOff(CutOff)
    /// The model finished with neither text nor a tool call.
    case emptyReply
    /// The turn used all its rounds of tool calls without a final answer.
    case tooManyRounds(Int)

    public var errorDescription: String? {
        switch self {
        case .turnInProgress: "A turn is already running in this conversation."
        case .replyCutOff(.length): "The reply was cut off: the model reached its output limit."
        case .replyCutOff(.contentFilter): "The reply was cut off by a content filter."
        case .emptyReply: "The model replied with nothing."
        case .tooManyRounds(let rounds): "The turn was stopped after \(rounds) rounds of tool calls without a final answer."
        }
    }
}

/// A conversation with a model and a set of tools. An actor: the
/// conversation is its state, and a turn is one call on it, which returns
/// when the turn is over. One turn runs at a time.
public actor ORAgent {
    private var client: OpenRouterClient
    private var model: String
    /// The reasoning effort asked of the model, when one is.
    private let reasoningEffort: String?
    /// How many tool rounds a single turn may take before it gives up.
    private let maxRounds: Int
    private let tools: [any ORTool]
    private let toolsByName: [String: any ORTool]
    /// The whole conversation, growing with each turn; the source of
    /// truth a consumer can read or persist.
    public private(set) var messages: [ORMessage]
    /// A turn suspends (on the model, on a tool), and the actor takes
    /// other calls meanwhile; a second turn among them would interleave
    /// its messages with the first's.
    private var isRunning = false

    /// - Parameter history: messages already had (resuming a conversation),
    ///   without the system prompt: what `history` gives back.
    public init(client: OpenRouterClient, model: String, tools: [any ORTool] = [], systemPrompt: String? = nil,
                history: [ORMessage] = [], reasoningEffort: String? = nil, maxRounds: Int = ORAgent.defaultMaxRounds) {
        self.client = client
        self.model = model
        self.tools = tools
        self.reasoningEffort = reasoningEffort
        self.maxRounds = maxRounds
        toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        messages = (systemPrompt.map { [ORMessage(role: .system, content: $0)] } ?? []) + history
    }

    /// How many tool rounds a turn may take when nothing else is said.
    public static let defaultMaxRounds = 24

    /// An id for an assistant message: "msg_or_" and 32 hex digits.
    static func newMessageID() -> String {
        "msg_or_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The conversation without the system prompt: what a session on
    /// disk keeps, and what `init(history:)` takes back.
    public var history: [ORMessage] { messages.filter { $0.role != .system } }

    /// The model the next completion is asked of.
    public func setModel(_ model: String) { self.model = model }

    /// The client the next completion goes through (a new key).
    public func setClient(_ client: OpenRouterClient) { self.client = client }

    /// Runs a user turn to completion, reporting events as it goes, and
    /// returns when the model has replied without calling a tool: a
    /// return is a finished answer. A reply that failed, was cut off or
    /// was empty, and a turn that ran out of rounds, throw. Appends
    /// every message (user, assistant, tool results) to `messages` as it
    /// lands. Each event is awaited: the turn goes on when `onEvent`
    /// returns, so a consumer sees them in order and can read `history`
    /// from inside it.
    ///
    /// Cancelling the task interrupts the turn: the completion in flight
    /// is dropped, a running tool is cancelled, the tools not yet run are
    /// not run, and `send` throws `CancellationError` — after every tool
    /// call the model made has an answer in `messages`, so the
    /// conversation can go on from there.
    public func send(_ userText: String, onEvent: @Sendable (ORAgentEvent) async -> Void) async throws {
        guard !isRunning else { throw ORAgentError.turnInProgress }
        isRunning = true
        defer { isRunning = false }
        messages.append(ORMessage(role: .user, content: userText))
        await onEvent(.started)
        do {
            try await rounds(onEvent)
        } catch where Task.isCancelled {
            // Whatever a cancelled turn threw on its way out (the
            // transport has its own errors for it), it ended because it
            // was cancelled.
            throw CancellationError()
        }
    }

    private func rounds(_ onEvent: @Sendable (ORAgentEvent) async -> Void) async throws {
        for _ in 0..<maxRounds {
            try Task.checkCancellation()
            let request = ORChatRequest(model: model, messages: ORMessage.answeringEveryToolCall(messages), tools: tools,
                                        reasoningEffort: reasoningEffort)
            let messageID = Self.newMessageID()
            let completion = try await client.complete(request) { event in
                switch event {
                case .token(let text): await onEvent(.delta(text, messageID: messageID))
                case .usage(let prompt, let completion): await onEvent(.usage(prompt: prompt, completion: completion))
                }
            }
            var message = completion.message
            let cutOff = completion.finishReason.flatMap(ORAgentError.CutOff.init(rawValue:))
            // A reply cut off may have cut a tool call's arguments short:
            // its calls are neither kept nor run.
            if cutOff != nil { message.toolCalls = nil }
            let text = message.content ?? ""
            let calls = message.toolCalls ?? []
            if !text.isEmpty || !calls.isEmpty {
                messages.append(message)
                await onEvent(.assistant(message, id: messageID))
            }
            if let cutOff { throw ORAgentError.replyCutOff(cutOff) }
            if text.isEmpty, calls.isEmpty { throw ORAgentError.emptyReply }
            if calls.isEmpty { return }
            for call in calls {
                await onEvent(.toolCall(name: call.function.name, arguments: call.function.arguments, id: call.id))
                let answer = await answer(call)
                messages.append(ORMessage(role: .tool, content: answer.output, toolCallID: call.id, name: call.function.name))
                await onEvent(.toolResult(name: call.function.name, output: answer.output, id: call.id, isError: answer.isError))
            }
        }
        // Cancelled during the last round's tools: the loop's check never came.
        try Task.checkCancellation()
        throw ORAgentError.tooManyRounds(maxRounds)
    }

    /// Runs the tool a call names. Once the turn is cancelled nothing more
    /// is run, but the call is still answered: the API refuses a
    /// conversation in which a tool call was left open.
    private func answer(_ call: ORToolCall) async -> (output: String, isError: Bool) {
        if Task.isCancelled { return (ORMessage.notRun, true) }
        guard let tool = toolsByName[call.function.name] else { return ("Error: no tool named \(call.function.name)", true) }
        do {
            return (try await tool.call(arguments: call.function.arguments), false)
        } catch is CancellationError {
            return (ORMessage.stopped, true)
        } catch {
            return ("Error: \(error.localizedDescription)", true)
        }
    }
}
