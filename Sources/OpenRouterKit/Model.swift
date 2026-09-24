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
        public init(prompt: String?, completion: String?) { self.prompt = prompt; self.completion = completion }
    }

    public init(id: String, name: String? = nil, contextLength: Int? = nil, supportedParameters: [String]? = nil,
                pricing: Pricing? = nil, created: Double? = nil) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.supportedParameters = supportedParameters
        self.pricing = pricing
        self.created = created
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
/// the API, and the CLI refreshes it at most once a day.
public enum ORModelCache {
    public struct Contents: Codable, Sendable {
        /// Seconds since 1970.
        public var fetched: Double
        public var models: [ORModel]
        /// OpenRouter's programming category, in its order (the most
        /// used for coding first): what a picker's short list offers.
        public var programming: [String]?
    }

    public static var file: URL { ORConfig.directory.appendingPathComponent("models.json") }
    public static let maxAge: Double = 24 * 60 * 60

    public static func load() -> Contents? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Contents.self, from: data)
    }

    public static var isStale: Bool {
        guard let fetched = load()?.fetched else { return true }
        return Date().timeIntervalSince1970 - fetched > maxAge
    }

    public static func save(_ models: [ORModel], programming: [String]? = nil) throws {
        try FileManager.default.createDirectory(at: ORConfig.directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Contents(fetched: Date().timeIntervalSince1970, models: models, programming: programming))
        try data.write(to: file, options: .atomic)
    }

    /// Fetches the list and keeps it; the models, or a throw.
    @discardableResult
    public static func refresh(client: OpenRouterClient = OpenRouterClient()) async throws -> [ORModel] {
        let models = try await client.models()
        let programming = try? await client.models(category: "programming").map(\.id)
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

extension ORTool {
    /// The tool as the API's `tools` array wants it.
    var wire: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": toolDescription,
                "parameters": (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8))) ?? ["type": "object"],
            ],
        ]
    }
}

/// A request for one completion.
public struct ORChatRequest: Sendable {
    public var model: String
    public var messages: [ORMessage]
    public var tools: [any ORTool]
    public var temperature: Double?
    /// OpenRouter's reasoning effort ("low", "medium", "high"), for the
    /// models that take one; nil leaves the model's default.
    public var reasoningEffort: String?

    public init(model: String, messages: [ORMessage], tools: [any ORTool] = [], temperature: Double? = nil,
                reasoningEffort: String? = nil) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
    }
}

/// One piece of a streamed completion.
public enum ORStreamEvent: Sendable {
    /// More assistant text.
    case token(String)
    /// A tool call, assembled from its streamed fragments.
    case toolCall(ORToolCall)
    /// The completion ended; the reason, and the assistant message as it
    /// finished (text and any tool calls), to append to the conversation.
    case finished(reason: String?, message: ORMessage)
    /// The tokens the request and reply used, when reported.
    case usage(prompt: Int, completion: Int)
}

public struct OpenRouterError: LocalizedError {
    public let status: Int
    public let body: String
    public var errorDescription: String? { "OpenRouter \(status): \(body)" }
}
