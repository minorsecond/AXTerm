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
    /// What `dcd` was decided from, 0…1 — so a channel that reads busy can be
    /// asked why instead of guessed at. See `DataCarrierDetect`.
    var toneDiscrimination: Float = 0
    var slicerLocked: [Bool] = []
    var pllJitterBits: [Float] = []
    var framesDecoded: UInt64 = 0
    /// Transmissions heard on the channel, counted from the receiver's noise
    /// quieting rather than decoded (`NoiseQuietingDetector`). Set against
    /// `framesDecoded`, it tells a quiet channel from one the modem cannot
    /// read.
    var carriersHeard: UInt64 = 0
    var fcsErrors: UInt64 = 0
    var duplicatesSuppressed: UInt64 = 0
    var lastDecodingSlicer: Int?
    var framesPerSlicer: [UInt64] = []
    var lastDecodeAt: Date?

    // Transmit.
    var ptt = false
    var txQueueDepth = 0
    var framesSent: UInt64 = 0
    /// Frames the transmitter gave up on — the channel never cleared, or PTT
    /// was refused. Counted because "handed to the radio" and "went on the
    /// air" are different events, and only the radio knows which happened.
    var framesDropped: UInt64 = 0
    var txUnderruns: UInt64 = 0
    var rxOverruns: UInt64 = 0
    var channelBusy = false
    var waitingForChannel = false
    /// How long the radio takes to confirm PTT after it is asked to key,
    /// smoothed over transmissions (1/8 per sample, as the AX.25 2.2 SDL
    /// smooths SRT); nil before the first one. Through Warbler to an IC-705
    /// it has taken as long as 3.6 s.
    var pttConfirmSeconds: Double?
    /// The TX delay this modem sends before each frame, seconds.
    var txDelaySeconds: Double = 0

    /// How long from asking to key until a frame starts on the air: PTT
    /// confirmation, the radio's audio buffer, and the TX delay. Floors a
    /// new link's initial SRT (AX.25 2.2 §6.7.1.1, spec §7.3).
    var keyUpSeconds: Double {
        (pttConfirmSeconds ?? 0) + latency.outputSeconds + txDelaySeconds
    }

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
