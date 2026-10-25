// The bytes of a body that arrives in pieces, one at a time: what the
// line reader (Lines.swift) takes.

import Foundation

/// The bytes of a sequence of `Data`, in order.
public struct DataPieceBytes<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element == Data {
    public typealias Element = UInt8

    let base: Base

    public init(base: Base) { self.base = base }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var piece = Data()
        var index = Data().startIndex

        public mutating func next() async throws -> UInt8? {
            while index == piece.endIndex {
                guard let next = try await base.next() else { return nil }
                piece = next
                index = next.startIndex
            }
            defer { index = piece.index(after: index) }
            return piece[index]
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }
}
