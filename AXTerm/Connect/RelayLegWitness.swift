//
//  RelayLegWitness.swift
//  AXTerm
//
//  Reading a relay hop's outcome off the air instead of out of a node's prose.
//
//  When BPQ is asked to connect onward it does not dial as itself: it dials as
//  the operator, under an SSID it assigns. Asking DRLNOD for KB5YZB-7 put
//  `K0EPI-6 → KB5YZB-7 SABM` on the air, and KB5YZB-7's UA came back to that
//  address — the entire hop, in AX.25, two seconds before DRLNOD got round to
//  saying `###LINK MADE` on the link we hold (field capture 2026-08-27).
//
//  The telling is the fragile part. That confirmation travels as a single
//  I-frame, and when it is lost the node does not resend it: on 2026-08-27 the
//  frame carrying the second hop's `###LINK MADE` never arrived, REJ went
//  unanswered, and the attempt was abandoned as failed while the far node sat
//  there connected. A UA is not prose. It needs no per-vendor wording, it is
//  fifteen bytes rather than a hundred and twenty-eight, and it travels on a
//  different link — so it survives what the announcement does not.
//
//  Deliberately one-sided evidence. Only the node's *own* outward connect is
//  visible this way, and only when this station can hear the far end; a chain
//  past the first hop is nodes connecting to nodes under identities of their
//  choosing, most of them out of earshot. So a verdict means something and
//  silence means nothing at all — never read the absence of one as failure.
//

import Foundation

nonisolated struct RelayLegWitness {

    enum Verdict: Equatable {
        /// The far station answered the node's SABM with UA: the hop is up.
        case made(hop: String)
        /// It answered DM — the AX.25 way of saying it is not accepting
        /// connections. A refusal, and one no wording list has to know.
        case refused(hop: String)
    }

    /// This station's callsign with the SSID stripped — the base a node
    /// borrows when it dials out on our behalf.
    private let base: String

    /// Every address this station answers to. The borrowed one is by
    /// definition not among them: the node picked a free SSID precisely so
    /// its outward link would not collide with ours.
    private let ours: Set<String>

    /// The station the node was last asked to reach, uppercased. Nil when no
    /// ask is outstanding, which is when this watches nothing.
    private var target: String?

    /// The SSID the node assigned, learned from its outgoing SABM. Nil until
    /// that frame is heard — and it may never be.
    private var leg: String?

    init(localCallsign: String, answers: [String]) {
        base = CallsignQuery.normalize(localCallsign)
        ours = Set(answers.map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
    }

    /// Arm for one hop: the station a node has just been asked to connect to.
    mutating func expect(_ hop: String) {
        target = hop.trimmingCharacters(in: .whitespaces).uppercased()
        leg = nil
    }

    /// Disarm. Anything overheard now belongs to somebody else's connect.
    mutating func stopWatching() {
        target = nil
        leg = nil
    }

    /// Feed a frame this station is not party to. Returns a verdict on the
    /// rare frames that carry one.
    mutating func observe(from: String, to: String, uType: AX25UType?) -> Verdict? {
        guard let target, let uType else { return nil }
        let source = from.trimmingCharacters(in: .whitespaces).uppercased()
        let destination = to.trimmingCharacters(in: .whitespaces).uppercased()

        // Outbound: the node dialling the hop under our borrowed callsign.
        // Learning the SSID is the whole reason to watch SABM — without it
        // the answer coming back is addressed to a station we have never
        // heard of and reads as somebody else's traffic.
        if destination == target, isBorrowed(source), uType == .SABM || uType == .SABME {
            leg = source
            return nil
        }

        // Inbound: the hop's own answer, addressed to the borrowed callsign.
        guard let leg, source == target, destination == leg else { return nil }
        switch uType {
        case .UA: return .made(hop: target)
        case .DM: return .refused(hop: target)
        default: return nil
        }
    }

    /// Our callsign, but not one of our addresses.
    ///
    /// Both halves matter. Without the first, any station's connect to the
    /// hop would be read as ours; without the second, this station's *own*
    /// link to the node would be — and that one is guaranteed to be on the
    /// air at exactly the moment we are watching.
    private func isBorrowed(_ call: String) -> Bool {
        CallsignQuery.normalize(call) == base && !ours.contains(call)
    }
}
