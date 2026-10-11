//
//  XIDAnswerMemory.swift
//  AXTerm
//
//  What each peer's link layer said about XID, remembered across launches.
//
//  A station that answers our XID command told us its firmware generation:
//  a v2.2 stack answers XID with XID, everything older rejects it — DM
//  from modern-but-pre-2.2 stacks (BPQ; the polite v2.2-era "no such
//  link"), FRMR from TNC-2-vintage firmware reporting an unimplemented
//  control field (W0ARP-10, field capture 2026-08-28 19:06). Either way
//  the answer is a property of the *station*, not of any session — so
//  re-probing on every launch spends a frame and, on a lossy channel, up
//  to a full RTO per connect to relearn a fact already known.
//
//  Only *answered* rejections are remembered. Silence is channel loss as
//  often as it is old firmware, and remembering it would permanently skip
//  negotiation with a peer that supports it. One kind of silence is an
//  answer: an XID unanswered while the SABM right after it is answered,
//  which is what Dire Wolf does (it keeps no link state before a SABM).
//  Two such connects in a row count as a rejection. An XID answer clears the
//  memory — and, because firmware does get upgraded, a remembered
//  rejection also *expires*: after roughly a month the probe is asked
//  once more. The expiry is jittered per station (a deterministic hash of
//  the callsign spreads it across two further weeks) so a directory of
//  peers learned in one evening does not all come due for re-probing in
//  the same evening a month later.
//

import Foundation

nonisolated struct XIDAnswerMemory {

    private let defaults: UserDefaults
    private static let key = "transmission.xidUnsupportedPeersV2"
    /// V1 stored a bare list of callsigns; migrated on first load with the
    /// migration date as the remembered-at date.
    private static let legacyKey = "transmission.xidUnsupportedPeers"

    /// Base lifetime of a remembered rejection.
    static let revalidateAfter: TimeInterval = 30 * 24 * 3600
    /// Each station's expiry lands somewhere in the two weeks after the
    /// base lifetime, spread by its callsign.
    static let revalidateJitterSpan: TimeInterval = 14 * 24 * 3600

    private var unsupported: [String: Date]

    /// Peers whose XID went unanswered while the SABM after it was
    /// answered, and how many times running. Dire Wolf drops an XID that
    /// arrives before the link is up, so it does this on every connect.
    private var silentThenConnected: [String: Int]
    private static let silentKey = "transmission.xidSilentThenConnected"
    /// Times running before the peer counts as not answering XID. Once
    /// could be one lost frame.
    static let silentThenConnectedLimit = 2

    init(defaults: UserDefaults = AppEnvironment.defaults, now: Date = Date()) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: Date].self, from: data) {
            unsupported = stored
        } else if let legacy = defaults.stringArray(forKey: Self.legacyKey) {
            unsupported = Dictionary(uniqueKeysWithValues: legacy.map { ($0, now) })
            defaults.removeObject(forKey: Self.legacyKey)
            Self.save(unsupported, to: defaults)
        } else {
            unsupported = [:]
        }
        silentThenConnected = defaults.dictionary(forKey: Self.silentKey) as? [String: Int] ?? [:]
    }

    private static func normalize(_ peer: String) -> String {
        peer.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// Deterministic per-station spread inside the jitter span — djb2 over
    /// the callsign, so the same station always expires at the same age
    /// and different stations at different ones.
    static func jitter(for peer: String) -> TimeInterval {
        var hash: UInt64 = 5381
        for byte in normalize(peer).utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return TimeInterval(hash % UInt64(revalidateJitterSpan))
    }

    /// The peer answered a previous XID with DM or FRMR recently enough to
    /// still trust: skip the probe and go straight to SABM. An expired
    /// entry answers false, so the next connect re-asks the question once
    /// — and the fresh answer re-arms the memory.
    func isKnownUnsupported(_ peer: String, now: Date = Date()) -> Bool {
        let key = Self.normalize(peer)
        guard let rememberedAt = unsupported[key] else { return false }
        let lifetime = Self.revalidateAfter + Self.jitter(for: key)
        return now.timeIntervalSince(rememberedAt) < lifetime
    }

    /// Record an *answered* verdict — a DM or FRMR to our XID
    /// (`unsupported: true`), or an actual XID exchange
    /// (`unsupported: false`, which also clears an old rejection).
    mutating func remember(_ peer: String, unsupported answered: Bool,
                           at now: Date = Date()) {
        let key = Self.normalize(peer)
        guard !key.isEmpty else { return }
        if !answered, silentThenConnected.removeValue(forKey: key) != nil {
            defaults.set(silentThenConnected, forKey: Self.silentKey)
        }
        if answered {
            unsupported[key] = now
        } else if unsupported.removeValue(forKey: key) == nil {
            return
        }
        Self.save(unsupported, to: defaults)
    }

    /// Our XID went unanswered and the SABM after it was answered: the peer
    /// heard us and skips XID before the link is up. After
    /// `silentThenConnectedLimit` such connects in a row it is remembered
    /// like a DM or FRMR, with the same expiry.
    mutating func rememberSilentThenConnected(_ peer: String, at now: Date = Date()) {
        let key = Self.normalize(peer)
        guard !key.isEmpty else { return }
        let count = (silentThenConnected[key] ?? 0) + 1
        if count >= Self.silentThenConnectedLimit {
            silentThenConnected.removeValue(forKey: key)
            defaults.set(silentThenConnected, forKey: Self.silentKey)
            remember(key, unsupported: true, at: now)
        } else {
            silentThenConnected[key] = count
            defaults.set(silentThenConnected, forKey: Self.silentKey)
        }
    }

    private static func save(_ entries: [String: Date], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
