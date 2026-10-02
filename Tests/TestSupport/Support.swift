// What the tests share: a transport that answers from canned bodies, a
// tool, and somewhere to keep the events a turn reports.

import Foundation
import OpenRouterKit

/// A transport that answers from canned bodies and SSE lines, so the
/// client and agent run without a network. An actor: the client calls it
/// from its own tasks, and the tests read what it saw.
public actor MockTransport: ORTransport {
    /// A line that is never sent: the stream stays open at it, as a reply
    /// does while the model is still writing, until whoever reads it
    /// stops.
    public static let stall = "(stall)"

    private let dataBody: Data
    private let status: Int
    /// SSE line batches, one per completion the agent asks for, in order.
    private let streams: [[String]]
    private var index = 0
    /// The bodies of the completions asked for, in order.
    public private(set) var sentBodies: [Data] = []
    /// The Authorization header of the last plain request, if it had one.
    public private(set) var lastAuthorization: String?

    public init(streams: [[String]] = [], status: Int = 200, dataBody: Data = Data()) {
        self.streams = streams
        self.status = status
        self.dataBody = dataBody
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        return (dataBody, try response(to: request))
    }

    public func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        if let body = request.httpBody { sentBodies.append(body) }
        let batch = index < streams.count ? streams[index] : []
        index += 1
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let feeding = Task {
                for line in batch {
                    if line == Self.stall {
                        do { try await Task.sleep(for: .seconds(3600)) } catch { break }
                    }
                    continuation.yield(line)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in feeding.cancel() }
        }
        return (stream, try response(to: request))
    }

    /// The messages of each completion asked for, as sent.
    public func sentMessages() throws -> [[[String: String]]] {
        try sentBodies.map { body in
            let root = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let messages = root?["messages"] as? [[String: Any]] ?? []
            return messages.map { $0.compactMapValues { $0 as? String } }
        }
    }

    private func response(to request: URLRequest) throws -> HTTPURLResponse {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badURL)
        }
        return response
    }
}

/// One SSE data line carrying a JSON object.
public func sse(_ object: [String: Any]) throws -> String {
    "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// The SSE lines of a completion that says `text` and stops.
public func reply(_ text: String) throws -> [String] {
    [try sse(["choices": [["delta": ["content": text], "finish_reason": "stop"]]]), "data: [DONE]"]
}

/// The SSE lines of a completion that asks for tools: (id, name, arguments).
public func toolCalls(_ calls: [(id: String, name: String, arguments: [String: Any])]) throws -> [String] {
    var lines: [String] = []
    for (index, call) in calls.enumerated() {
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: call.arguments), as: UTF8.self)
        lines.append(try sse(["choices": [["delta": ["tool_calls": [["index": index, "id": call.id, "function": ["name": call.name, "arguments": arguments]]]]]]]))
    }
    lines.append(try sse(["choices": [["delta": [String: Any](), "finish_reason": "tool_calls"]]]))
    lines.append("data: [DONE]")
    return lines
}

public struct EchoTool: ORTool {
    public let name = "echo"
    public let toolDescription = "Echo the text back."
    public let parametersJSON = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"
    public init() {}
    public func call(arguments: String) async throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
        return object?["text"] as? String ?? ""
    }
}

/// Keeps the events a turn reports, in order.
public actor Recorder {
    public private(set) var events: [ORAgentEvent] = []
    public init() {}
    public func add(_ event: ORAgentEvent) { events.append(event) }
}

/// A folder of the test's own.
public func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("openrouterkit-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
