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
                "Not sent — \(summary.destination.display) has not accepted the circuit yet. "
                + "Your message is still in the box.")
        case .disconnecting:
            return .circuitNotReady(
                "Not sent — the circuit to \(summary.destination.display) is closing.")
        case .disconnected:
            return .circuitNotReady(
                "Not sent — the circuit to \(summary.destination.display) is closed.")
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
