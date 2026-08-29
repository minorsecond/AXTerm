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
//  negotiation with a peer that supports it. An XID answer clears the
//  memory — firmware gets upgraded.
//

import Foundation

nonisolated struct XIDAnswerMemory {

    private let defaults: UserDefaults
    private static let key = "transmission.xidUnsupportedPeers"
    private var unsupported: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.stringArray(forKey: Self.key) {
            unsupported = Set(stored)
        } else {
            unsupported = []
        }
    }

    private static func normalize(_ peer: String) -> String {
        peer.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// The peer has answered a previous XID with DM or FRMR: skip the
    /// probe and go straight to SABM.
    func isKnownUnsupported(_ peer: String) -> Bool {
        unsupported.contains(Self.normalize(peer))
    }

    /// Record an *answered* verdict — a DM or FRMR to our XID
    /// (`unsupported: true`), or an actual XID exchange
    /// (`unsupported: false`, which also clears an old rejection).
    mutating func remember(_ peer: String, unsupported answered: Bool) {
        let key = Self.normalize(peer)
        guard !key.isEmpty else { return }
        let before = unsupported
        if answered {
            unsupported.insert(key)
        } else {
            unsupported.remove(key)
        }
        guard unsupported != before else { return }
        defaults.set(Array(unsupported).sorted(), forKey: Self.key)
    }
}
