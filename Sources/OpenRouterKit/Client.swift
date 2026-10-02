// The OpenRouter API client: the model list, and a chat completion read as
// it is streamed. The transport is injectable so tests drive it without a
// network.

import Foundation

/// What actually moves the bytes. The real one is URLSession; a test
/// gives its own.
public protocol ORTransport: Sendable {
    /// A GET/POST returning the whole body.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// A POST whose body is read a line at a time, as the lines arrive
    /// (Server-Sent Events). Whoever iterates the lines reads the body:
    /// when that task is cancelled, the reading stops.
    func lines(for request: URLRequest) async throws -> (any AsyncSequence<String, any Error> & Sendable, HTTPURLResponse)
}

public struct OpenRouterClient: Sendable {
    public let apiKey: String
    private let transport: any ORTransport

    private static let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    /// How the requests name their sender to OpenRouter.
    private static let referer = "https://github.com/AttilaTheFun/open_router_cli"
    private static let title = "openrouter"

    /// - Parameters:
    ///   - apiKey: defaults to the resolved key (`ORConfig.resolvedKey`:
    ///     the environment, else the config file).
    ///   - transport: defaults to URLSession's.
    public init(apiKey: String? = nil, transport: (any ORTransport)? = nil) {
        self.apiKey = apiKey ?? ORConfig.resolvedKey() ?? ""
        self.transport = transport ?? URLSessionTransport()
    }

    public var hasKey: Bool { !apiKey.isEmpty }

    private func authorized(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Without a key, no header: the model list is public, and only a
        // chat needs one.
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue(Self.referer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(Self.title, forHTTPHeaderField: "X-Title")
        return request
    }

    /// Asks OpenRouter whether it knows the key (`GET /key`), and throws
    /// `OpenRouterError` (401) when it does not. The model list cannot
    /// tell: it is public, and answers whatever key it is asked with.
    public func checkKey() async throws {
        let (data, response) = try await transport.data(for: authorized(Self.baseURL.appendingPathComponent("key"), method: "GET"))
        guard (200..<300).contains(response.statusCode) else {
            throw OpenRouterError(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }

    /// The models OpenRouter offers, id-sorted; with a category
    /// ("programming"), that category's models in OpenRouter's order.
    public func models(category: String? = nil) async throws -> [ORModel] {
        var url = Self.baseURL.appendingPathComponent("models")
        if let category, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = [URLQueryItem(name: "category", value: category)]
            url = parts.url ?? url
        }
        let (data, response) = try await transport.data(for: authorized(url, method: "GET"))
        guard (200..<300).contains(response.statusCode) else {
            throw OpenRouterError(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        struct List: Decodable { let data: [ORModel] }
        let list = try JSONDecoder().decode(List.self, from: data).data
        return category == nil ? list.sorted { $0.id < $1.id } : list
    }

    /// Asks for one completion and returns it when it is whole: the
    /// assistant message, and why the model stopped. As the reply is
    /// streamed, each piece of it is handed to `onEvent`, which is
    /// awaited. Throws when the request is refused (`OpenRouterError`),
    /// when the reply fails or is cut short on the way (`ORStreamError`),
    /// and `CancellationError` when the task is cancelled, which stops
    /// the reading: what is returned is only ever a completion the API
    /// said was complete.
    public func complete(_ chat: ORChatRequest, onEvent: @Sendable (ORStreamEvent) async -> Void) async throws -> ORCompletion {
        do {
            return try await read(chat, onEvent: onEvent)
        } catch where Task.isCancelled {
            // A transport has its own error for a request that was
            // cancelled under it; whatever it threw, the completion ended
            // because the task was cancelled.
            throw CancellationError()
        }
    }

    private func read(_ chat: ORChatRequest, onEvent: @Sendable (ORStreamEvent) async -> Void) async throws -> ORCompletion {
        var request = authorized(Self.baseURL.appendingPathComponent("chat/completions"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.body(chat)
        let (lines, response) = try await transport.lines(for: request)
        guard (200..<300).contains(response.statusCode) else {
            var body = ""
            for try await line in lines { body += line }
            throw OpenRouterError(status: response.statusCode, body: body)
        }
        var assembler = StreamAssembler()
        var sawDone = false
        for try await line in lines {
            // Server-Sent Events: only data lines matter here; the rest
            // are comments (keep-alives) and blanks.
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { sawDone = true; break }
            for event in try assembler.ingest(Data(payload.utf8)) { await onEvent(event) }
        }
        // A transport's lines may simply end when the task is cancelled:
        // that is a cancellation, not a reply cut short.
        try Task.checkCancellation()
        return try assembler.finish(sawDone: sawDone)
    }

    /// The body of a completion request, as the API takes it.
    private struct Body: Encodable {
        struct Reasoning: Encodable {
            let effort: String
        }

        struct Tool: Encodable {
            struct Function: Encodable {
                let name: String
                let description: String
                let parameters: JSONValue
            }

            let type = "function"
            let function: Function
        }

        let model: String
        let messages: [ORMessage]
        let stream = true
        let reasoning: Reasoning?
        let tools: [Tool]?
    }

    static func body(_ chat: ORChatRequest) throws -> Data {
        let tools = try chat.tools.map { tool in
            Body.Tool(function: .init(name: tool.name, description: tool.toolDescription, parameters: try tool.parameters()))
        }
        let effort = chat.reasoningEffort.flatMap { $0.isEmpty ? nil : Body.Reasoning(effort: $0) }
        let encoder = JSONEncoder()
        // Keys in one order, so that a request is the same bytes from one
        // process to the next (a provider's prompt cache goes by them).
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try encoder.encode(Body(model: chat.model, messages: chat.messages, reasoning: effort, tools: tools.isEmpty ? nil : tools))
    }
}
