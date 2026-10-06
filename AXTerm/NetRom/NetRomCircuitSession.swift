//
//  NetRomCircuitSession.swift
//  AXTerm
//
//  A NET/ROM circuit as a terminal session.
//
//  CLAUDE.md §5 lists NET/ROM circuits as one of the session types
//  AXTerm must model, alongside AX.25 connected mode and BBS sessions.
//  The Terminal already keys its session picker, transcript filter, and
//  compose target off a string record id, so a circuit joins that list
//  by minting a record id of its own rather than by growing a parallel
//  UI.
//
//  This type holds the pure part of that — id minting, lookup, and the
//  decision of where typed text goes — so the routing can be tested
//  without a view.
//

import Foundation

nonisolated enum NetRomCircuitSession {

    /// Namespace for circuit session ids, so they can never collide with
    /// the AX.25 records (which are keyed by destination + path).
    static let recordPrefix = "netrom-circuit:"

    static func recordID(for id: NetRomCircuitID) -> String {
        recordPrefix + id.raw.uuidString
    }

    static func isCircuitRecord(_ recordID: String) -> Bool {
        recordID.hasPrefix(recordPrefix)
    }

    /// Resolve a session record id back to a live circuit. Returns nil
    /// for AX.25 records and for circuits that have since closed — the
    /// record can outlive the circuit in the picker.
    static func circuit(forRecordID recordID: String,
                        among circuits: [NetRomCircuitSummary]) -> NetRomCircuitSummary? {
        guard isCircuitRecord(recordID) else { return nil }
        return circuits.first { Self.recordID(for: $0.id) == recordID }
    }

    /// The address a circuit's pane filters its lines by: the callsign on
    /// the air. The display name ("EPINDB (K0EPI-3)") is no address, and
    /// filtering by it left the pane empty (smoke run 2026-10-03-1, 7.2).
    static func transcriptPeer(for summary: NetRomCircuitSummary) -> String {
        summary.destination.display
    }

    /// The session record that typed text and Disconnect act on.
    ///
    /// The Sessions picker only filters what is shown. With a session picked,
    /// that session; with All Traffic, the live circuit the compose bar points
    /// at, when the bar is set to NET/ROM. Until 2026-10-06 All Traffic sent
    /// typing as plain AX.25 text on the neighbor link and Disconnect dropped
    /// that link, with the circuit still up (smoke run 2026-10-03-1, issue 76).
    static func composeRecordID(activeRecordID: String?,
                                barIsNetRom: Bool,
                                barDestination: String,
                                circuits: [NetRomCircuitSummary]) -> String? {
        if let activeRecordID { return activeRecordID }
        guard barIsNetRom else { return nil }
        let wanted = barDestination.trimmingCharacters(in: .whitespaces).uppercased()
        guard !wanted.isEmpty else { return nil }
        let match = circuits
            .filter { $0.state == .connecting || $0.state == .connected }
            .filter { $0.destination.display.uppercased() == wanted
                || $0.requestedAlias?.uppercased() == wanted }
            .max { $0.openedAt < $1.openedAt }
        return match.map { recordID(for: $0.id) }
    }

    /// Whether an AX.25 link counts as the operator's session for the
    /// compose bar. A link that has carried NET/ROM stays up for the node
    /// after its circuits close; with none riding it, it is not a session
    /// the operator has, and showing it as connected left the bar on
    /// Disconnect after "Circuit to K0EPI-3 closed." (issue 84).
    static func linkIsOperatorSession(carriesNetRom: Bool,
                                      peer: AX25Address,
                                      circuits: [NetRomCircuitSummary]) -> Bool {
        guard carriesNetRom else { return true }
        return circuits.contains { circuit in
            circuit.state != .disconnected
                && CallsignNormalizer.addressesMatch(circuit.neighbor, peer)
        }
    }

    /// Whether the circuit the connect bar shows has just closed, so the
    /// bar should go back to a draft. The bar otherwise follows the AX.25
    /// link underneath, which stays up for the node after the circuit is
    /// gone (smoke run 2026-10-03-1, issue 84). Only a circuit that was up
    /// counts: a node-prompt relay also shows as NET/ROM and has none.
    static func barSessionEnded(barDestination: String,
                                barIsNetRomSession: Bool,
                                before: [NetRomCircuitSummary],
                                after: [NetRomCircuitSummary]) -> Bool {
        guard barIsNetRomSession else { return false }
        let wanted = barDestination.trimmingCharacters(in: .whitespaces).uppercased()
        guard !wanted.isEmpty else { return false }
        func liveToBar(_ circuits: [NetRomCircuitSummary]) -> Bool {
            circuits.contains { circuit in
                (circuit.state == .connecting || circuit.state == .connected)
                    && (circuit.destination.display.uppercased() == wanted
                        || circuit.requestedAlias?.uppercased() == wanted)
            }
        }
        return liveToBar(before) && !liveToBar(after)
    }

    /// Where the compose field's text should go.
    enum SendTarget: Equatable {
        /// A live, established circuit.
        case circuit(NetRomCircuitID)
        /// A circuit that exists but cannot carry text yet. Carries the
        /// operator-facing reason.
        case circuitNotReady(String)
        /// Anything else — the existing AX.25 / relay path.
        case ax25
    }

    /// Decide where typed text goes, given what the operator has
    /// selected in the session picker.
    ///
    /// Deliberately refuses to send into a circuit that is still coming
    /// up: the words are meant for the far end, and NET/ROM has nowhere
    /// to put them until CONACK arrives. Same reasoning as the relay
    /// handshake guard in `sendConnectedMessage`.
    static func sendTarget(activeRecordID: String?,
                           circuits: [NetRomCircuitSummary]) -> SendTarget {
        guard let activeRecordID,
              isCircuitRecord(activeRecordID) else { return .ax25 }
        guard let summary = circuit(forRecordID: activeRecordID, among: circuits) else {
            return .circuitNotReady("That circuit is closed. Open it again to send.")
        }
        switch summary.state {
        case .connected:
            return .circuit(summary.id)
        case .connecting:
            return .circuitNotReady(
                "Not sent: \(summary.destination.display) has not accepted the circuit yet. "
                + "Your message is still in the box.")
        case .disconnecting:
            return .circuitNotReady(
                "Not sent: the circuit to \(summary.destination.display) is closing.")
        case .disconnected:
            return .circuitNotReady(
                "Not sent: the circuit to \(summary.destination.display) is closed.")
        }
    }

    /// Status text for the session picker, matching the wording the
    /// AX.25 records use ("Connected", "Failed", …) so one list does not
    /// read in two dialects.
    static func statusText(for state: NetRomCircuitState) -> String {
        switch state {
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting…"
        case .disconnected: return "Disconnected"
        }
    }
}
