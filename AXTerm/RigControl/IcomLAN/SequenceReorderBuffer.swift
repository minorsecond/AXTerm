import Foundation

/// Puts a stream of numbered datagrams back in order.
///
/// UDP loses and reorders. The radio numbers what it sends and will send a
/// packet again when asked, so a small hold — 100 ms — lets a late or
/// re-sent packet slot in before its turn passes. A packet still missing
/// when its turn comes is released as `nil`, so audio can be padded with
/// silence and the stream keeps time. Sequence numbers wrap at 0xFFFF.
nonisolated struct SequenceReorderBuffer {
    /// A packet in order, or nil for one that never came.
    typealias Release = (UInt16, Data?) -> Void
    typealias RequestRetransmit = ([UInt16]) -> Void

    let holdSeconds: Double
    private(set) var nextExpected: UInt16?
    private var waiting: [UInt16: Data] = [:]
    private var gapSince: Double?
    private var requested: Set<UInt16> = []
    private(set) var released = 0
    private(set) var lost = 0
    private(set) var lateDuplicates = 0

    init(holdSeconds: Double = 0.1) {
        self.holdSeconds = holdSeconds
    }

    /// Distance forward from `a` to `b` around the ring.
    static func forwardDistance(from a: UInt16, to b: UInt16) -> Int {
        Int(b &- a)
    }

    mutating func add(sequence: UInt16, data: Data, now: Double,
                      release: Release, requestRetransmit: RequestRetransmit) {
        guard let expected = nextExpected else {
            nextExpected = sequence &+ 1
            released += 1
            release(sequence, data)
            return
        }
        let ahead = Self.forwardDistance(from: expected, to: sequence)
        if ahead == 0 {
            released += 1
            release(sequence, data)
            nextExpected = expected &+ 1
            requested.remove(sequence)
            flush(release: release)
            if waiting.isEmpty { gapSince = nil }
            return
        }
        if ahead > 32_768 {
            // Behind: already released, or given up on. A late retransmit.
            lateDuplicates += 1
            return
        }
        waiting[sequence] = data
        if gapSince == nil { gapSince = now }
        // Ask once for each packet between what we expected and this one.
        var missing: [UInt16] = []
        var s = expected
        while s != sequence && missing.count < 32 {
            if !requested.contains(s), waiting[s] == nil { missing.append(s); requested.insert(s) }
            s &+= 1
        }
        if !missing.isEmpty { requestRetransmit(missing) }
        tick(now: now, release: release)
    }

    /// Time passing: give up on gaps older than the hold.
    mutating func tick(now: Double, release: Release) {
        guard let expected = nextExpected, let since = gapSince, !waiting.isEmpty else { return }
        guard now - since >= holdSeconds else { return }
        // Skip to the oldest waiting packet, reporting each missing one.
        let oldest = waiting.keys.min { Self.forwardDistance(from: expected, to: $0) < Self.forwardDistance(from: expected, to: $1) }!
        var s = expected
        while s != oldest {
            lost += 1
            requested.remove(s)
            release(s, nil)
            s &+= 1
        }
        nextExpected = oldest
        flush(release: release)
        gapSince = waiting.isEmpty ? nil : now
    }

    private mutating func flush(release: Release) {
        guard var expected = nextExpected else { return }
        while let data = waiting.removeValue(forKey: expected) {
            released += 1
            requested.remove(expected)
            release(expected, data)
            expected &+= 1
        }
        nextExpected = expected
    }

    mutating func reset() {
        nextExpected = nil
        waiting.removeAll()
        gapSince = nil
        requested.removeAll()
    }
}
