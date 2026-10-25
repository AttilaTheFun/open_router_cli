// A file handle's bytes as they arrive (stdin's stream-json, say): what
// Apple's `FileHandle.bytes` gives, which Linux's Foundation does not have.

import Foundation

extension FileHandle {
    /// What is read from the handle, a piece at a time, until its end. The
    /// reads block, so they run on a thread of their own, not one of the
    /// tasks' shared ones.
    public var arrivingPieces: AsyncThrowingStream<Data, any Error> {
        let (pieces, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let thread = Thread { [self] in
            do {
                while let piece = try read(upToCount: 64 * 1024), !piece.isEmpty {
                    continuation.yield(piece)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        thread.name = "openrouter: reading"
        thread.start()
        return pieces
    }

    /// The handle's lines, ended by a line feed only, as they arrive.
    public var arrivingLines: LineFeedLines<DataPieceBytes<AsyncThrowingStream<Data, any Error>>> {
        DataPieceBytes(base: arrivingPieces).lineFeedLines
    }
}
