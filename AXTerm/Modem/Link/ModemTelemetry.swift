import Foundation

/// What the modem knows about itself, assembled off the audio thread a few
/// times a second for the level meter, the DCD and PTT dots, and the log.
nonisolated struct ModemTelemetry: Equatable, Sendable {
    // Receive audio.
    var rxPeakDBFS: Float = -120
    var rxRMSDBFS: Float = -120
    var rxClipping = false

    // Decoding.
    var dcd = false
    var slicerLocked: [Bool] = []
    var pllJitterBits: [Float] = []
    var framesDecoded: UInt64 = 0
    var fcsErrors: UInt64 = 0
    var duplicatesSuppressed: UInt64 = 0
    var lastDecodingSlicer: Int?
    var framesPerSlicer: [UInt64] = []
    var lastDecodeAt: Date?

    // Transmit.
    var ptt = false
    var txQueueDepth = 0
    var framesSent: UInt64 = 0
    var txUnderruns: UInt64 = 0
    var rxOverruns: UInt64 = 0
    var channelBusy = false
    var waitingForChannel = false

    // Audio.
    var audioFormat: ModemAudioFormat?
    var latency = ModemAudioLatency()

    var lastError: String?
    var uptime: TimeInterval = 0

    init() {}

    static func dbfs(_ linear: Float) -> Float {
        linear <= 0 ? -120 : max(-120, 20 * log10(linear))
    }
}
