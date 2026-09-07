import Foundation
import Synchronization

/// A single-producer, single-consumer ring of samples.
///
/// One thread writes (the audio thread capturing, or the DSP thread queuing
/// output), one thread reads. Head and tail are atomics with acquire/release
/// ordering and nothing else is shared, so neither side ever blocks — which
/// is the whole requirement on the real-time thread.
nonisolated final class SPSCRingBuffer: @unchecked Sendable {

    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let head = Atomic<Int>(0)   // next write position
    private let tail = Atomic<Int>(0)   // next read position
    private let mask: Int

    /// Capacity is rounded up to a power of two.
    init(capacity requested: Int) {
        var c = 1
        while c < requested { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
    }

    deinit { storage.deallocate() }

    var availableToRead: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .acquiring)
    }
    var availableToWrite: Int { capacity - availableToRead }

    /// Write as many as fit; returns how many were written.
    @discardableResult
    func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        guard let base = samples.baseAddress else { return 0 }
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let room = capacity - (h - t)
        let n = min(room, samples.count)
        for i in 0..<n { storage[(h + i) & mask] = base[i] }
        head.store(h + n, ordering: .releasing)
        return n
    }

    @discardableResult
    func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { write($0) }
    }

    /// Read up to `into.count`; returns how many were read.
    @discardableResult
    func read(into: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let base = into.baseAddress else { return 0 }
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let n = min(h - t, into.count)
        for i in 0..<n { base[i] = storage[(t + i) & mask] }
        tail.store(t + n, ordering: .releasing)
        return n
    }

    func read(count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let n = out.withUnsafeMutableBufferPointer { read(into: $0) }
        if n < count { out.removeLast(count - n) }
        return out
    }

    /// Consumer-side: discard everything queued.
    func drain() {
        tail.store(head.load(ordering: .acquiring), ordering: .releasing)
    }
}
