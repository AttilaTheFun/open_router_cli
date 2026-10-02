// The OpenRouter wire types and the agent's own vocabulary. Only what the
// library needs; the API has more.

import Foundation

/// A model OpenRouter offers.
public struct ORModel: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    /// "Provider: Model", as OpenRouter names it.
    public let name: String?
    /// The context window in tokens, when the API gives one.
    public let contextLength: Int?
    /// The request parameters the model takes ("tools", "reasoning", …).
    public let supportedParameters: [String]?
    /// Dollars per token, as decimal strings ("0.00000005").
    public let pricing: Pricing?
    /// When OpenRouter listed it (seconds since 1970): newer is later.
    public let created: Double?

    public struct Pricing: Codable, Hashable, Sendable {
        public let prompt: String?
        public let completion: String?
    }

    /// Whether it can call tools (the agent needs this).
    public var supportsTools: Bool { supportedParameters?.contains("tools") ?? false }

    /// Dollars per million tokens in and out, when priced.
    public var pricePerMillion: (input: Double, output: Double)? {
        guard let input = pricing?.prompt.flatMap(Double.init), let output = pricing?.completion.flatMap(Double.init) else { return nil }
        return (input * 1_000_000, output * 1_000_000)
    }

    public var isFree: Bool { id.hasSuffix(":free") || pricePerMillion.map { $0.input == 0 && $0.output == 0 } ?? false }

    enum CodingKeys: String, CodingKey {
        case id, name, pricing, created
        case contextLength = "context_length"
        case supportedParameters = "supported_parameters"
    }
}

/// OpenRouter's model list, kept on disk (~/.openrouter/models.json) so a
/// host that shows it — Visor's model picker — reads a file rather than
/// the API. `openrouter models` fetches it afresh; a headless run fetches
/// it when what is on disk is more than a day old.
public struct ORModelCache: Sendable {
    public struct Contents: Codable, Sendable {
        /// Seconds since 1970.
        public var fetched: Double
        public var models: [ORModel]
        /// OpenRouter's programming category, in its order (the most
        /// used for coding first): what a picker's short list offers.
        public var programming: [String]?
    }

    public let file: URL
    /// How old the list may be before a headless run fetches it again.
    public static let maxAge: Double = 24 * 60 * 60

    public init(file: URL = ORConfig.directory().appendingPathComponent("models.json")) {
        self.file = file
    }

    public func load() -> Contents? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Contents.self, from: data)
    }

    /// Whether there is no list on disk, or one older than `maxAge`.
    public var isStale: Bool {
        guard let fetched = load()?.fetched else { return true }
        return Date().timeIntervalSince1970 - fetched > Self.maxAge
    }

    public func save(_ models: [ORModel], programming: [String]?) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Contents(fetched: Date().timeIntervalSince1970, models: models, programming: programming))
        try data.write(to: file, options: .atomic)
    }

    /// Fetches the list and keeps it; the models, or a throw. The
    /// programming category is a second request: when only that one
    /// fails, the category already on disk is kept with the new list,
    /// not wiped.
    @discardableResult
    public func refresh(client: OpenRouterClient) async throws -> [ORModel] {
        let models = try await client.models()
        let programming = (try? await client.models(category: "programming").map(\.id)) ?? load()?.programming
        try save(models, programming: programming)
        return models
    }
}

/// A turn in the conversation, as OpenRouter's chat API wants it.
public struct ORMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var content: String?
    /// On an assistant turn: the tool calls it asked for.
    public var toolCalls: [ORToolCall]?
    /// On a tool turn: which call this answers.
    public var toolCallID: String?
    /// A name for a tool result, some models want it.
    public var name: String?

    public init(role: Role, content: String? = nil, toolCalls: [ORToolCall]? = nil, toolCallID: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

extension ORMessage {
    /// What answers a tool call the turn was interrupted before running.
    static let notRun = "Interrupted: the turn was stopped before this ran."
    /// What answers a tool call that was running when the turn was interrupted.
    static let stopped = "Interrupted: the turn was stopped while this was running."
    /// What answers a tool call with no answer on record.
    static let unanswered = "Interrupted: no result was recorded for this call."

    /// The conversation as the API takes it: every tool call answered,
    /// directly after the message that made it. A conversation the agent
    /// kept is already so; one from a process that was killed with a tool
    /// running, or from a build that saved an interrupted turn as it
    /// stood, is not, and is refused until it is. A call's answer is
    /// looked for up to the next message that makes calls; a call with
    /// none gets `unanswered`; an answer to no call is left out.
    static func answeringEveryToolCall(_ messages: [ORMessage]) -> [ORMessage] {
        var result: [ORMessage] = []
        for (index, message) in messages.enumerated() where message.role != .tool {
            result.append(message)
            guard message.role == .assistant, let calls = message.toolCalls, !calls.isEmpty else { continue }
            let rest = messages[(index + 1)...]
            let end = rest.firstIndex { $0.role == .assistant && !($0.toolCalls ?? []).isEmpty } ?? messages.endIndex
            var answers = rest[..<end].filter { $0.role == .tool }
            for call in calls {
                if let found = answers.firstIndex(where: { $0.toolCallID == call.id }) {
                    result.append(answers.remove(at: found))
                } else {
                    result.append(ORMessage(role: .tool, content: unanswered, toolCallID: call.id, name: call.function.name))
                }
            }
        }
        return result
    }
}

/// A tool call the model asked for.
public struct ORToolCall: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var type: String
    public var function: Function

    public struct Function: Codable, Hashable, Sendable {
        public var name: String
        /// The arguments as a JSON string, as the API sends them.
        public var arguments: String
        public init(name: String, arguments: String) { self.name = name; self.arguments = arguments }
    }

    public init(id: String, type: String = "function", function: Function) {
        self.id = id
        self.type = type
        self.function = function
    }
}

/// A tool the model may call: its name, what it is for, and the shape of
/// its arguments (a JSON Schema object). Consumers implement `call`.
public protocol ORTool: Sendable {
    var name: String { get }
    var toolDescription: String { get }
    /// The parameters as a JSON Schema object, encoded.
    var parametersJSON: String { get }
    /// Runs the tool with the model's arguments (a JSON object string),
    /// returning the result text the model sees next.
    func call(arguments: String) async throws -> String
}

/// A tool whose `parametersJSON` is not a JSON object: the request cannot
/// describe it to the model.
public struct ORToolSchemaError: LocalizedError, Equatable {
    public let tool: String
    public var errorDescription: String? { "The parameters of the tool \"\(tool)\" are not a JSON object." }
}

extension ORTool {
    /// The tool's parameters as the API's `tools` array wants them: a
    /// JSON object. Throws when `parametersJSON` is not one: sent as
    /// "takes anything", the model would call the tool blind.
    func parameters() throws -> JSONValue {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(parametersJSON.utf8)), case .object = value else {
            throw ORToolSchemaError(tool: name)
        }
        return value
    }
}

/// Any JSON value: what a tool's parameter schema is made of.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A request for one completion.
public struct ORChatRequest: Sendable {
    public var model: String
    public var messages: [ORMessage]
    public var tools: [any ORTool]
    /// OpenRouter's reasoning effort ("low", "medium", "high"), for the
    /// models that take one; nil leaves the model's default.
    public var reasoningEffort: String?

    public init(model: String, messages: [ORMessage], tools: [any ORTool] = [], reasoningEffort: String? = nil) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.reasoningEffort = reasoningEffort
    }
}

/// One piece of a completion, as it is streamed.
public enum ORStreamEvent: Sendable {
    /// More assistant text.
    case token(String)
    /// The tokens the request and reply used, when reported.
    case usage(prompt: Int, completion: Int)
}

/// A completion, whole.
public struct ORCompletion: Sendable, Equatable {
    /// The assistant message: its text and any tool calls.
    public let message: ORMessage
    /// Why the model stopped, as the API gives it ("stop", "tool_calls",
    /// "length", "content_filter"); nil when it gave no reason.
    public let finishReason: String?
}

/// The API refused a request: the HTTP status and the body it sent.
public struct OpenRouterError: LocalizedError, Equatable {
    public let status: Int
    public let body: String
    public var errorDescription: String? { "OpenRouter \(status): \(body)" }
}

/// A streamed completion that did not complete.
public enum ORStreamError: LocalizedError, Equatable {
    /// The stream carried an error: the provider failed after the reply
    /// had begun.
    case failed(code: String?, message: String)
    /// The stream ended with nothing saying the completion had: the
    /// connection was lost, or something between cut it short.
    case incomplete
    /// A data line was not a completion chunk; the start of it.
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let code, let message): "OpenRouter failed during the reply: \(message)" + (code.map { " (\($0))" } ?? "")
        case .incomplete: "The reply was cut off: the stream ended before the model finished."
        case .malformed(let start): "OpenRouter sent something that is not a completion: \(start)"
        }
    }
}
