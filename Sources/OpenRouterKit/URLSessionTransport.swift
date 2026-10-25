// The real transport: URLSession, with the streamed body read as lines
// (ended by a line feed only: see Lines.swift) as they arrive.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct URLSessionTransport: ORTransport {
    /// What each request's session is made with (a test puts its own
    /// protocol in front of the network).
    private let configuration: @Sendable () -> URLSessionConfiguration

    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .default }) {
        self.configuration = configuration
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (lines, response) = try await body(for: request)
        var data = Data()
        for try await piece in lines { data.append(piece) }
        return (data, response)
    }

    public func lines(for request: URLRequest) async throws -> (any AsyncSequence<String, any Error> & Sendable, HTTPURLResponse) {
        let (pieces, response) = try await body(for: request)
        return (DataPieceBytes(base: pieces).lineFeedLines, response)
    }

    /// The response, and the body's pieces as they come.
    private func body(for request: URLRequest) async throws -> (AsyncThrowingStream<Data, any Error>, HTTPURLResponse) {
        let task = StreamingDataTask()
        let response = try await task.start(request, configuration: configuration())
        return (task.body, response)
    }
}
