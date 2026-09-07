import Foundation

/// Is somebody transmitting?
///
/// Carrier detect comes from the decoder, not the squelch: a slicer hearing
/// flags or data is a station on the air, whatever the noise floor. A short
/// hold covers the gaps between frames of one transmission, and a level
/// floor keeps decoder chatter on an open, empty channel from counting.
nonisolated struct DataCarrierDetect: Sendable {

    let holdSamples: Int64
    private var lastActiveAt: Int64 = .min / 2
    private(set) var isDetected = false

    init(holdSamples: Int) {
        self.holdSamples = Int64(max(0, holdSamples))
    }

    mutating func update(activity: HDLCDecoder.Activity, rmsDBFS: Float, squelchDBFS: Float, now: Int64) -> Bool {
        if activity != .idle, rmsDBFS >= squelchDBFS {
            lastActiveAt = now
        }
        isDetected = now - lastActiveAt <= holdSamples
        return isDetected
    }

    mutating func reset() {
        lastActiveAt = .min / 2
        isDetected = false
    }
}
