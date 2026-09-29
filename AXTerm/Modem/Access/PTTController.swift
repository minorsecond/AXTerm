import Foundation

/// Keys the transmitter.
///
/// Called from the modem's DSP thread, so it must never block: it starts the
/// key-down (a CI-V command, a serial line, nothing) and reports through the
/// completion, on any thread. The engine plays no audio until the completion
/// says the radio is keyed, and treats an error as "do not transmit".
nonisolated protocol PTTController: AnyObject {
    /// How long after `setTransmit(false)` the carrier is actually gone —
    /// a hint the engine adds to its unkey margin.
    var keyUpLatencyHint: TimeInterval { get }
    func setTransmit(_ on: Bool, completion: @escaping @Sendable (Error?) -> Void)
}

/// VOX, a footswitch, or a radio somebody else keys: the modem only plays audio.
nonisolated final class NoPTTController: PTTController, @unchecked Sendable {
    var keyUpLatencyHint: TimeInterval { 0 }
    init() {}
    func setTransmit(_ on: Bool, completion: @escaping @Sendable (Error?) -> Void) {
        completion(nil)
    }
}
