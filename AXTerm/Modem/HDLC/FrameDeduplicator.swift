import Foundation

/// Several slicers decode the same samples in lock-step, so one transmission
/// can come out of two or three of them a few bit-times apart. The first
/// copy is the frame; the rest are the same frame. A genuine repeat — a
/// retry, a digipeated copy — is at least a TXDELAY away and is delivered.
nonisolated struct FrameDeduplicator: Sendable {

    let windowBitTimes: Int64

    private struct Sighting { let hash: Int; let atBit: Int64 }
    private var recent: [Sighting] = []
    private(set) var suppressed: Int = 0

    init(windowBitTimes: Int = 64) {
        self.windowBitTimes = Int64(max(1, windowBitTimes))
    }

    /// Whether this decode is the first sighting of these bytes inside the
    /// window. `atBit` is the decoder's running bit clock.
    mutating func shouldDeliver(_ frame: Data, slicer: Int, atBit: Int64) -> Bool {
        recent.removeAll { atBit - $0.atBit > windowBitTimes }
        var hasher = Hasher()
        hasher.combine(frame)
        let hash = hasher.finalize()
        if recent.contains(where: { $0.hash == hash }) {
            suppressed += 1
            return false
        }
        recent.append(Sighting(hash: hash, atBit: atBit))
        return true
    }

    mutating func reset() { recent.removeAll() }
}
