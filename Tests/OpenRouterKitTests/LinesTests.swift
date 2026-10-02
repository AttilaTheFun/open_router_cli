// A line ends at a line feed and nowhere else: the characters Foundation's
// `lines` also splits at are ones JSON carries raw inside a string.

import Foundation
import Testing
@testable import OpenRouterKit
import TestSupport

/// Bytes as an asynchronous sequence, a few at a time.
private func bytes(_ text: String) -> AsyncStream<UInt8> {
    AsyncStream { continuation in
        for byte in Data(text.utf8) { continuation.yield(byte) }
        continuation.finish()
    }
}

private func lines(_ text: String) async throws -> [String] {
    var lines: [String] = []
    for try await line in bytes(text).lineFeedLines { lines.append(line) }
    return lines
}

@Test func aLineEndsAtALineFeedOnly() async throws {
    // A line separator, a paragraph separator, a next-line, a vertical tab
    // and a form feed: all inside the line they are in.
    let odd = "a\u{2028}b\u{2029}c\u{85}d\u{0B}e\u{0C}f"
    #expect(try await lines(odd + "\nnext\n") == [odd, "next"])
    // Which Foundation's own lines would cut into six.
    var cut = 0
    for try await _ in bytes(odd + "\n").lines { cut += 1 }
    #expect(cut == 6)
}

@Test func linesKeepTheirShape() async throws {
    #expect(try await lines("one\ntwo\n") == ["one", "two"])
    // What follows the last line feed is a line; nothing after it is not.
    #expect(try await lines("one\ntwo") == ["one", "two"])
    #expect(try await lines("") == [])
    #expect(try await lines("\n") == [""])
    // Empty lines are lines (Server-Sent Events end an event with one).
    #expect(try await lines("a\n\nb\n") == ["a", "", "b"])
    // A carriage return before the line feed goes; one anywhere else stays.
    #expect(try await lines("a\r\nb\rc\r\n") == ["a", "b\rc"])
    // Any text at all.
    #expect(try await lines("naïve ✓ 日本語\n") == ["naïve ✓ 日本語"])
}

/// A transport whose stream is these bytes, read as the real one reads its own.
private struct BytesTransport: ORTransport {
    let body: String

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(), try response(to: request))
    }

    func lines(for request: URLRequest) async throws -> (any AsyncSequence<String, any Error> & Sendable, HTTPURLResponse) {
        (bytes(body).lineFeedLines, try response(to: request))
    }

    private func response(to request: URLRequest) throws -> HTTPURLResponse {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badURL)
        }
        return response
    }
}

/// A reply with a line separator in its text arrives whole: the stream is
/// one JSON object to a line, and the separator is not a line's end.
@Test func aReplyWithALineSeparatorInItArrivesWhole() async throws {
    let text = "first\u{2028}second"
    // As a server writes it: the separator raw in the JSON, CRLF line ends, a blank line after each event.
    let body = "data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: [DONE]\r\n\r\n"
    let client = OpenRouterClient(apiKey: "k", transport: BytesTransport(body: body))
    let completion = try await client.complete(ORChatRequest(model: "m", messages: [])) { _ in }
    #expect(completion == ORCompletion(message: ORMessage(role: .assistant, content: text), finishReason: "stop"))
}
