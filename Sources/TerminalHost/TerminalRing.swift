import Foundation

/// The end of everything a shell has written, kept so a reader can leave and come back.
///
/// Every byte has a position counted from the shell's start. A reader who comes back asks to go on
/// from the position it reached; while the ring still holds that position the reader misses
/// nothing and repaints nothing. A reader that asks for a position the ring has let go of, or for
/// none, is started over at the oldest safe place the ring holds.
struct TerminalRing: Sendable {
    let limit: Int
    private var bytes: [UInt8] = []
    private var first = 0
    private(set) var startOffset: UInt64 = 0
    private var startState = EscapeScanner()

    init(limit: Int) {
        self.limit = max(limit, 4096)
    }

    private var held: Int { bytes.count - first }

    var endOffset: UInt64 { startOffset + UInt64(held) }

    mutating func append(_ chunk: UnsafeRawBufferPointer) {
        bytes.append(contentsOf: chunk)
        let excess = held - limit
        guard excess > 0 else { return }
        bytes.withUnsafeBytes { raw in
            startState.feed(UnsafeRawBufferPointer(rebasing: raw[first..<(first + excess)]))
        }
        first += excess
        startOffset += UInt64(excess)
        if first >= limit / 4 {
            bytes.removeFirst(first)
            first = 0
        }
    }

    /// The bytes from `offset` on, at most `limit` of them: nil when the ring no longer holds
    /// that position, empty when the reader has everything.
    func read(from offset: UInt64, limit: Int) -> Data? {
        guard offset >= startOffset, offset <= endOffset else { return nil }
        let skip = Int(offset - startOffset)
        let count = min(held - skip, limit)
        guard count > 0 else { return Data() }
        return bytes.withUnsafeBytes { raw in
            Data(UnsafeRawBufferPointer(rebasing: raw[(first + skip)..<(first + skip + count)]))
        }
    }

    /// Where a reader with nothing starts, and the modes the terminal was in there.
    ///
    /// The oldest byte held may be the middle of a colour change or of a character, so the start
    /// moves forward to the first place that is neither, preferring the start of a line when one
    /// is near.
    func replayStart() -> (offset: UInt64, preamble: Data) {
        var scanner = startState
        var skipped = 0
        var firstGround: (Int, EscapeScanner)?
        var previous: UInt8 = startOffset == 0 ? UInt8(ascii: "\n") : 0
        let window = min(held, 8192)
        bytes.withUnsafeBytes { raw in
            while skipped < window {
                if scanner.isGround {
                    if firstGround == nil { firstGround = (skipped, scanner) }
                    if previous == UInt8(ascii: "\n") {
                        firstGround = (skipped, scanner)
                        return
                    }
                }
                previous = raw[first + skipped]
                scanner.feed(previous)
                skipped += 1
            }
        }
        let chosen = firstGround ?? (0, startState)
        return (startOffset + UInt64(chosen.0), chosen.1.preamble())
    }
}
