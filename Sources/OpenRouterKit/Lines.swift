// Lines of text out of bytes, ended by a line feed and by nothing else.
//
// Both protocols here are a JSON object to a line: Server-Sent Events from
// the API, and stream-json on stdin. Foundation's `lines` also ends a line
// at U+2028, U+2029, U+0085, a vertical tab and a form feed, all of which
// JSON allows raw inside a string (and most encoders write raw): text with
// one in it would arrive as two halves, neither of them JSON.

import Foundation

/// The lines of a sequence of UTF-8 bytes: each ended by a line feed (a
/// carriage return before it is dropped), and whatever follows the last
/// line feed, if anything does. Empty lines are lines.
public struct LineFeedLines<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    public typealias Element = String

    let base: Base

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var line: [UInt8] = []
        var ended = false

        public mutating func next() async throws -> String? {
            guard !ended else { return nil }
            while let byte = try await base.next() {
                guard byte == 0x0A else {
                    line.append(byte)
                    continue
                }
                if line.last == 0x0D { line.removeLast() }
                defer { line.removeAll(keepingCapacity: true) }
                return String(decoding: line, as: UTF8.self)
            }
            ended = true
            return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }
}

extension LineFeedLines: Sendable where Base: Sendable {}

extension AsyncSequence where Element == UInt8 {
    /// The sequence's lines, ended by a line feed only.
    public var lineFeedLines: LineFeedLines<Self> { LineFeedLines(base: self) }
}
