// The real transport, with a protocol of the test's own in front of the
// network: a body that arrives in pieces is read a line at a time, a line
// split across pieces whole, and the status is the server's.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import OpenRouterKit

/// Answers every request with a status and a body in the pieces given.
final class PiecesProtocol: URLProtocol {
    static let status = 200
    static let pieces = ["data: {\"a\":1}\n\nda", "ta: {\"b\":2}\r\n", "\ndata: [DONE]\n"]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for piece in Self.pieces { client?.urlProtocol(self, didLoad: Data(piece.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let transport = URLSessionTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PiecesProtocol.self]
    return configuration
}

private let request = URLRequest(url: URL(string: "https://openrouter.test/api/v1/chat/completions")!)

@Test func aBodyInPiecesIsReadALineAtATime() async throws {
    let (lines, response) = try await transport.lines(for: request)
    #expect(response.statusCode == 200)
    var read: [String] = []
    for try await line in lines { read.append(line) }
    #expect(read == ["data: {\"a\":1}", "", "data: {\"b\":2}", "", "data: [DONE]"])
}

@Test func aWholeBodyIsEveryPiece() async throws {
    let (data, response) = try await transport.data(for: request)
    #expect(response.statusCode == 200)
    #expect(String(decoding: data, as: UTF8.self) == PiecesProtocol.pieces.joined())
}
