import Foundation

/// What the modem does after the last modulated sample of a transmission.
///
/// Every transmission ends with TXTAIL worth of HDLC flags, whatever the
/// policy: they are part of the frame on the air, and the receiver needs the
/// closing flag intact. The policy decides what comes after them.
nonisolated enum ModemTransmitTail: String, Equatable, Sendable {
    /// The modem drives the radio itself, over USB audio or the radio's own
    /// WLAN. The radio buffers transmit audio before it plays it, so the
    /// modem keeps the transmitter keyed for that buffer plus a margin after
    /// the last sample, and over the WLAN sends a little silence after the
    /// flags so the buffer plays out.
    case radio
    /// Warbler's virtual IC-705 stands in for the radio. Warbler holds a
    /// client's unkey until its own playout has drained and the radio's
    /// buffer has played, so the modem sends no trailing silence and unkeys
    /// as soon as the last sample has been handed to the link. Silence sent
    /// here would only keep Warbler's last-audio time moving and add to the
    /// carrier left on the air after the frame.
    case warbler

    /// Whether silence follows the flags on a network audio stream.
    var sendsTrailingSilence: Bool { self == .radio }

    /// Whether the engine waits out the radio's buffer and a margin after the
    /// last sample before it unkeys.
    var waitsForRadioBuffer: Bool { self == .radio }

    /// Why this policy, for the log.
    var reason: String {
        switch self {
        case .radio:
            return "the radio buffers transmit audio, so the modem keeps the key until it has played out"
        case .warbler:
            return "Warbler holds the unkey until its playout and the radio's buffer have drained"
        }
    }

    /// The policy for an Icom LAN session, from what its capabilities said.
    static func forIcomLAN(viaWarbler: Bool) -> ModemTransmitTail {
        viaWarbler ? .warbler : .radio
    }
}

/// Which 20 ms frames of transmit audio a network audio stream sends.
///
/// Frames carrying audio always go. So does silence while the engine still
/// has audio coming for the current transmission: a short render then is an
/// underrun, and the silence keeps the stream's timing so nothing after it
/// arrives early or out of place. After the transmission, a direct radio
/// gets `trailingSilenceFrames` of silence and then nothing; Warbler gets
/// none. An idle modem sends nothing, so it costs the network nothing.
nonisolated struct TrailingSilenceGate: Equatable, Sendable {
    /// 300 ms at 20 ms a frame.
    static let trailingSilenceFrames = 15

    let limit: Int
    private(set) var quietFrames = 0

    init(tail: ModemTransmitTail) {
        limit = tail.sendsTrailingSilence ? Self.trailingSilenceFrames : 0
    }

    /// Whether to send this frame. `written` is how many samples the engine
    /// rendered into it; `moreToCome` is true while the engine is still
    /// producing audio for the transmission in progress.
    mutating func shouldSend(written: Int, moreToCome: Bool) -> Bool {
        if written > 0 || moreToCome {
            quietFrames = 0
            return true
        }
        quietFrames += 1
        return quietFrames <= limit
    }
}
