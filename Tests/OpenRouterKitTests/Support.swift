// What the tests share: a transport that answers from canned bodies, a
// tool, and somewhere to keep the events a turn reports.

import Foundation
import Testing
@testable import OpenRouterKit

/// A transport that answers from canned bodies and SSE lines, so the
/// client and agent run without a network. An actor: the client calls it
/// from its own tasks, and the tests read what it saw.
actor MockTransport: ORTransport {
    private let dataBody: Data
    private let status: Int
    /// SSE line batches, one per completion the agent asks for, in order.
    private let streams: [[String]]
    private var index = 0
    /// The bodies of the completions asked for, in order.
    private(set) var sentBodies: [Data] = []
    /// The Authorization header of the last plain request, if it had one.
    private(set) var lastAuthorization: String?

    init(streams: [[String]] = [], status: Int = 200, dataBody: Data = Data()) {
        self.streams = streams
        self.status = status
        self.dataBody = dataBody
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        return (dataBody, try response(to: request))
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        if let body = request.httpBody { sentBodies.append(body) }
        let batch = index < streams.count ? streams[index] : []
        index += 1
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in batch { continuation.yield(line) }
            continuation.finish()
        }
        return (stream, try response(to: request))
    }

    private func response(to request: URLRequest) throws -> HTTPURLResponse {
        let url = try #require(request.url)
        return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    }
}

/// One SSE data line carrying a JSON object.
func sse(_ object: [String: Any]) throws -> String {
    "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
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

/// Keeps the events a turn reports, in order.
actor Recorder {
    private(set) var events: [ORAgentEvent] = []
    func add(_ event: ORAgentEvent) { events.append(event) }
}

/// A folder of the test's own.
func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("openrouterkit-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
