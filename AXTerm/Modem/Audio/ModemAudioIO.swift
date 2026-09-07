import Foundation

/// The audio a modem runs on, as a protocol, so the DSP never knows whether
/// the samples came from a USB codec, a network stream or a test.
nonisolated struct ModemAudioFormat: Equatable, Sendable {
    let sampleRate: Double
    let inputChannels: Int
    let outputChannels: Int
}

/// Hints only: device-reported latencies are unreliable, and the engine
/// accounts for the output by counting consumed samples instead.
nonisolated struct ModemAudioLatency: Equatable, Sendable {
    var inputSeconds: Double = 0
    var outputSeconds: Double = 0
}

nonisolated struct ModemAudioDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    let nominalSampleRate: Double
    /// "USB", "Built-in", "Bluetooth", … as the system names it.
    let transport: String
    var id: String { uid }
}

nonisolated enum ModemAudioIOEvent: Equatable, Sendable {
    case started(ModemAudioFormat)
    case deviceLost
    case formatChanged(ModemAudioFormat)
    case overload
    case error(String)
}

/// What the audio hands to and pulls from the engine.
///
/// `didCapture` and `render` run on the real-time audio thread: no
/// allocation, no locks, no logging, nothing that can block. `didReceive`
/// is called off that thread.
nonisolated protocol ModemAudioSink: AnyObject {
    /// Mono samples at the device rate.
    func audioIO(didCapture samples: UnsafeBufferPointer<Float>, hostTime: UInt64)
    /// Fill mono output; return how many were written (the rest is silence).
    func audioIO(render into: UnsafeMutableBufferPointer<Float>) -> Int
    func audioIO(didReceive event: ModemAudioIOEvent)
}

nonisolated protocol ModemAudioIO: AnyObject {
    /// Known once started.
    var format: ModemAudioFormat? { get }
    var latency: ModemAudioLatency { get }
    var sink: ModemAudioSink? { get set }
    /// May block briefly; called off the main thread.
    func start() throws
    func stop()
}

nonisolated enum ModemAudioError: Error, Equatable, Sendable {
    case deviceNotFound(uid: String)
    case permissionDenied
    case unsupportedFormat(String)
    case system(code: Int32, stage: String)
}
