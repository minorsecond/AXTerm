import Foundation

/// Recognises one transmission heard by two radios.
///
/// Two radios on one frequency hear the same frame. Without this, the second
/// copy reached the retry tracker inside its two-second window and was scored
/// as a *failed delivery* — on a shared channel df collapsed toward 0.5 for
/// perfectly delivered traffic — and every count (packets, airtime, path
/// observations) doubled.
///
/// The key is the exact AX.25 bytes. A digipeated copy differs by its
/// has-been-repeated bits, so it is rightly two air events; and the same
/// station cannot legitimately retransmit identical bytes inside the window,
/// so identical bytes on *different* radios inside it can only be one
/// transmission. The window sits between the ingestion-dedup window (0.25 s)
/// and the retry window (2 s) on purpose: a fold can never be mistaken for
/// either. Same-radio repeats are not this type's business — the per-radio
/// duplicate tracker keeps its own meaning for those.
nonisolated struct CrossRadioDedup {

    enum Admission: Equatable {
        /// The first hearing of these bytes: this is the packet.
        case first
        /// The same transmission, heard by another radio inside the window.
        case additionalRadio(firstRadio: RadioID)
        /// The same radio again inside the window: not ours to judge.
        case sameRadioRepeat
    }

    /// Wide enough for two TNCs to decode and deliver the same frame — a local
    /// Direwolf is well under 100 ms, a TNC across the internet a few hundred —
    /// and narrower than the retry window, so nothing folded here could have
    /// been a retry.
    static let defaultWindow: TimeInterval = 1.5
    /// Entries kept before the oldest are dropped, whatever their age.
    static let capacity = 2048

    let window: TimeInterval

    private struct Sighting {
        let radio: RadioID
        let at: Date
        var radios: Set<RadioID>
    }
    private var recent: [Data: Sighting] = [:]
    private var order: [Data] = []

    init(window: TimeInterval = CrossRadioDedup.defaultWindow) {
        self.window = window
    }

    mutating func admit(raw: Data, radio: RadioID, at now: Date) -> Admission {
        prune(before: now.addingTimeInterval(-window))
        if var sighting = recent[raw], now.timeIntervalSince(sighting.at) <= window {
            if sighting.radios.contains(radio) { return .sameRadioRepeat }
            sighting.radios.insert(radio)
            recent[raw] = sighting
            return .additionalRadio(firstRadio: sighting.radio)
        }
        recent[raw] = Sighting(radio: radio, at: now, radios: [radio])
        order.append(raw)
        if order.count > Self.capacity {
            let dropped = order.removeFirst()
            recent.removeValue(forKey: dropped)
        }
        return .first
    }

    private mutating func prune(before cutoff: Date) {
        while let oldest = order.first, let sighting = recent[oldest], sighting.at < cutoff {
            order.removeFirst()
            recent.removeValue(forKey: oldest)
        }
    }
}
