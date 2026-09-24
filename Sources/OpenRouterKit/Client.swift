// The OpenRouter API client: model listing and a streamed chat completion.
// The transport is injectable so tests drive it without a network.

import Foundation

/// What actually moves the bytes. The real one is URLSession; a test
/// gives its own.
public protocol ORTransport: Sendable {
    /// A GET/POST returning the whole body.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// A POST returning Server-Sent Event lines as they arrive.
    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
}

public struct OpenRouterClient: Sendable {
    public let apiKey: String
    public let baseURL: URL
    public let referer: String
    public let title: String
    private let transport: any ORTransport

    /// - Parameter apiKey: defaults to the resolved key (`ORConfig.resolvedKey`:
    ///   the environment, else the config file).
    public init(apiKey: String? = nil,
                baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
                referer: String = "https://github.com/AttilaTheFun/open_router_cli",
                title: String = "openrouter",
                transport: (any ORTransport)? = nil) {
        self.apiKey = apiKey ?? ORConfig.resolvedKey() ?? ""
        self.baseURL = baseURL
        self.referer = referer
        self.title = title
        self.transport = transport ?? URLSessionTransport()
    }

    public var hasKey: Bool { !apiKey.isEmpty }

    private func authorized(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        request.setValue(title, forHTTPHeaderField: "X-Title")
        return request
    }

    /// The models OpenRouter offers, id-sorted; with a category
    /// ("programming"), that category's models in OpenRouter's order.
    public func models(category: String? = nil) async throws -> [ORModel] {
        var url = baseURL.appendingPathComponent("models")
        if let category, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = [URLQueryItem(name: "category", value: category)]
            url = parts.url ?? url
        }
        let (data, response) = try await transport.data(for: authorized(url, method: "GET"))
        guard (200..<300).contains(response.statusCode) else {
            throw OpenRouterError(status: response.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        struct List: Decodable { let data: [ORModel] }
        let list = try JSONDecoder().decode(List.self, from: data).data
        return category == nil ? list.sorted { $0.id < $1.id } : list
    }

    /// Streams one completion, yielding tokens and tool calls as they come
    /// and a `finished` at the end with the assembled assistant message.
    public func stream(_ chat: ORChatRequest) -> AsyncThrowingStream<ORStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = authorized(baseURL.appendingPathComponent("chat/completions"), method: "POST")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try Self.body(chat)
                    let (lines, response) = try await transport.lines(for: request)
                    guard (200..<300).contains(response.statusCode) else {
                        var body = ""
                        for try await line in lines { body += line }
                        throw OpenRouterError(status: response.statusCode, body: body)
                    }
                    var assembler = StreamAssembler()
                    for try await line in lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        for event in assembler.ingest(data) { continuation.yield(event) }
                    }
                    continuation.yield(assembler.finish())
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func body(_ chat: ORChatRequest) throws -> Data {
        var object: [String: Any] = [
            "model": chat.model,
            "messages": try messagesJSON(chat.messages),
            "stream": true,
        ]
        if let temperature = chat.temperature { object["temperature"] = temperature }
        if let effort = chat.reasoningEffort, !effort.isEmpty { object["reasoning"] = ["effort": effort] }
        if !chat.tools.isEmpty { object["tools"] = chat.tools.map(\.wire) }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func messagesJSON(_ messages: [ORMessage]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(messages)
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }
}
