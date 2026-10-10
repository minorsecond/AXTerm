@testable import AXTerm

extension AX25Session {
    /// Bytes waiting in the queue, not yet numbered. Queued data is held
    /// whole and cut into frames when it goes out (retest 2026-10-10,
    /// finding 13), so the entry count no longer says how many frames wait.
    var pendingBytes: Int { pendingDataQueue.reduce(0) { $0 + $1.data.count } }

    /// How many frames the queued bytes make at the paclen in force.
    var pendingFrameCount: Int {
        let paclen = max(1, livePaclen)
        return pendingDataQueue.reduce(0) { $0 + ($1.data.count + paclen - 1) / paclen }
    }
}
