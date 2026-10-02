// The real transport: URLSession, with the streamed body read as lines.

import Foundation

public struct URLSessionTransport: ORTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        return (data, try Self.http(response))
    }

    public func lines(for request: URLRequest) async throws -> (any AsyncSequence<String, any Error> & Sendable, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        return (bytes.lines, try Self.http(response))
    }

    /// The response as HTTP's, which the API's always is; anything else is
    /// not an answer from it, and has no status to call a success.
    private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http
    }
}
