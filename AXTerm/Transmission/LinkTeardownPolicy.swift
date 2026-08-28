//
//  LinkTeardownPolicy.swift
//  AXTerm
//
//  When the app decides a link is over, what — if anything — goes on the air?
//
//  The judgement is small but it burned a whole morning (2026-08-28): the
//  relay's "dropping the link so the next attempt starts clean" path used
//  forceDisconnect, which transmits nothing, so BPQ at the far end kept the
//  session and answered the next SABM as a *reset* — already past its
//  greeting, and a node only greets on a fresh connect. Separated out, like
//  [[NetRomAutoTryPolicy]], because "what does the peer still believe" is a
//  question worth testing without a radio.
//

import Foundation

nonisolated enum LinkTeardownPolicy {

    /// How to end a session so that both sides agree it ended.
    enum Action: Equatable {
        /// The peer holds session state of its own; release it with a real
        /// DISC. The state machine retries on T1 and gives up by itself if
        /// the path has died in the meantime.
        case sendDISC
        /// Nothing established on the far side worth releasing — a DISC
        /// from here would retry for minutes against a peer that never
        /// answered. Tear down locally only.
        case dropLocally
    }

    /// Only a connected session provably has a mirror on the far side.
    /// Everything short of that (SABM unanswered, already disconnecting,
    /// error) either has no far-end state or is already releasing it.
    static func action(for state: AX25SessionState) -> Action {
        state == .connected ? .sendDISC : .dropLocally
    }
}
