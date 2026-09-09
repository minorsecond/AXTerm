import Foundation

/// Whether a radio on the other end of a UDP session is still there.
///
/// The Icom LAN protocol runs entirely over UDP, so there is no connection to
/// lose and no error to catch: a radio that has dropped us, a Wi-Fi router
/// that has stopped forwarding, and macOS refusing the app local-network
/// access all look exactly alike from inside the app — our datagrams keep
/// being accepted by the kernel and nothing ever comes back.
///
/// The operator's log of 2026-09-09 is what this exists for. At 11:48:49Z the
/// sockets to the IC-705 died (`Local network prohibited` on `en7`), the radio
/// stopped showing a client, and AXTerm reported it as connected for the next
/// two hours. Silence was the only evidence available and nobody was measuring
/// it.
nonisolated enum IcomLANLiveness {

    /// How long the radio may say nothing at all before we call it gone.
    ///
    /// It pings us several times a second, we answer each one, and once audio
    /// is running there is a packet every few milliseconds. A second of quiet
    /// is already unusual. Ten leaves generous room for a busy Mac or a brief
    /// Wi-Fi stumble while still telling the operator inside a breath — and it
    /// is far shorter than the two minutes the token renewal takes to notice,
    /// which was the only check there was.
    static let silenceLimit: TimeInterval = 10

    /// The streams whose silence is evidence. Control and audio both carry
    /// traffic continuously once connected; the serial stream carries CI-V
    /// only when somebody is asking the radio something, so quiet there is its
    /// resting state and must never be read as death.
    static let watchedStreams = ["control", "audio"]

    /// Why the link should be failed, or nil while it is healthy.
    static func complaint(silentFor: TimeInterval, limit: TimeInterval = silenceLimit) -> String? {
        guard silentFor >= limit else { return nil }
        return "the radio stopped answering — nothing received for "
            + String(Int(silentFor.rounded()))
            + " seconds. Check that it is still on, still on the network, and "
            + "that this Mac is allowed to reach devices on the local network."
    }

    /// The same question from a timestamp. A session that has never heard
    /// anything is not silent: the handshake has its own timeout, and a zero
    /// stamp must not read as an eternity the moment the watchdog starts.
    static func complaint(lastInboundAt: Double, now: Double,
                          limit: TimeInterval = silenceLimit) -> String? {
        guard lastInboundAt > 0 else { return nil }
        return complaint(silentFor: now - lastInboundAt, limit: limit)
    }
}
