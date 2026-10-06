import XCTest
@testable import AXTerm

/// A NET/ROM circuit presented as a terminal session: id minting,
/// lookup, and — the part that matters on the air — where typed text is
/// allowed to go.
final class NetRomCircuitSessionTests: XCTestCase {

    private let cosco = AX25Address(call: "COSCO", ssid: 0)
    private let drlnod = AX25Address(call: "DRLNOD", ssid: 0)

    private func summary(_ state: NetRomCircuitState,
                         destination: AX25Address? = nil,
                         neighbor: AX25Address? = nil) -> NetRomCircuitSummary {
        NetRomCircuitSummary(
            id: NetRomCircuitID(),
            destination: destination ?? cosco,
            neighbor: neighbor ?? drlnod,
            state: state,
            openedAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - Record ids

    func testCircuitRecordIdsAreNamespaced() {
        let id = NetRomCircuitID()
        let record = NetRomCircuitSession.recordID(for: id)
        XCTAssertTrue(NetRomCircuitSession.isCircuitRecord(record))
        XCTAssertTrue(record.hasPrefix("netrom-circuit:"))
    }

    func testAX25RecordIdsAreNotMistakenForCircuits() {
        // AX.25 records are keyed by destination and path; none of those
        // shapes may ever resolve to a circuit.
        for candidate in ["KB5YZB-7", "KB5YZB-7|DRLNOD", "", "COSCO"] {
            XCTAssertFalse(NetRomCircuitSession.isCircuitRecord(candidate),
                           "\(candidate) is an AX.25 record")
            XCTAssertNil(NetRomCircuitSession.circuit(forRecordID: candidate, among: []))
        }
    }

    func testLookupFindsTheRightCircuitAmongSeveral() {
        let a = summary(.connected, destination: cosco)
        let b = summary(.connected, destination: AX25Address(call: "EVANS", ssid: 0))
        let found = NetRomCircuitSession.circuit(
            forRecordID: NetRomCircuitSession.recordID(for: b.id), among: [a, b])
        XCTAssertEqual(found?.id, b.id)
        XCTAssertEqual(found?.destination.display, "EVANS")
    }

    // MARK: - The circuit's transcript

    /// A circuit's pane shows the lines to and from the station on the
    /// circuit. It was filtered by the display name, "EPINDB (K0EPI-3)",
    /// which no line carries, so the pane stayed empty while the node
    /// answered (smoke run 2026-10-03-1, 7.2).
    func testACircuitsTranscriptIsFilteredByTheCallsignOnTheAir() {
        let station = AX25Address(call: "K0EPI", ssid: 3)
        var circuit = summary(.connected, destination: station, neighbor: station)
        circuit.requestedAlias = "EPINDB"
        XCTAssertEqual(circuit.displayName, "EPINDB (K0EPI-3)")

        let peer = NetRomCircuitSession.transcriptPeer(for: circuit)
        XCTAssertEqual(peer, "K0EPI-3")

        let lines: [ConsoleLine] = [
            .packet(from: "K0EPI-3", to: "K0EPI-2", text: "AXTerm Node EPINDB:K0EPI-3"),
            .packet(from: "K0EPI-2", to: "K0EPI-3", text: "N"),
            .packet(from: "N0FH-10", to: "BEACON", text: "unrelated")
        ]
        XCTAssertEqual(TerminalSessionLineFilter.apply(lines, peer: peer).map(\.text),
                       ["AXTerm Node EPINDB:K0EPI-3", "N"])
    }

    // MARK: - Which session typing and Disconnect act on

    /// The Sessions picker filters what is shown. With All Traffic selected,
    /// typing went out as plain AX.25 text on the neighbor link and
    /// Disconnect sent DISC on it, while the compose bar still said NET/ROM
    /// to K0EPI-3 and the circuit was up (smoke run 2026-10-03-1, issue 76).
    /// What the bar points at decides.
    func testAllTrafficLeavesTypingWithTheCircuitTheBarPointsAt() {
        let station = AX25Address(call: "K0EPI", ssid: 3)
        var circuit = summary(.connected, destination: station, neighbor: station)
        circuit.requestedAlias = "EPINDB"
        let record = NetRomCircuitSession.recordID(for: circuit.id)

        for bar in ["K0EPI-3", "EPINDB", "k0epi-3"] {
            XCTAssertEqual(NetRomCircuitSession.composeRecordID(
                activeRecordID: nil, barIsNetRom: true, barDestination: bar, circuits: [circuit]),
                record, "bar \(bar)")
        }
        // The picker's own choice still wins.
        XCTAssertEqual(NetRomCircuitSession.composeRecordID(
            activeRecordID: "W0ARP-1", barIsNetRom: true, barDestination: "K0EPI-3", circuits: [circuit]),
            "W0ARP-1")
        // An AX.25 bar, another station, or no live circuit: nothing to adopt.
        XCTAssertNil(NetRomCircuitSession.composeRecordID(
            activeRecordID: nil, barIsNetRom: false, barDestination: "K0EPI-3", circuits: [circuit]))
        XCTAssertNil(NetRomCircuitSession.composeRecordID(
            activeRecordID: nil, barIsNetRom: true, barDestination: "W0ARP-1", circuits: [circuit]))
        XCTAssertNil(NetRomCircuitSession.composeRecordID(
            activeRecordID: nil, barIsNetRom: true, barDestination: "K0EPI-3",
            circuits: [summary(.disconnected, destination: station, neighbor: station)]))
    }

    // MARK: - The connect bar when its circuit closes

    /// Smoke run 2026-10-03-1, issue 84: after "Circuit to K0EPI-3 closed."
    /// the bar still read connected, NET/ROM, K0EPI-3, with Disconnect,
    /// because it follows the AX.25 link underneath, and that link stays up
    /// for the node.
    func testTheBarsCircuitClosingEndsTheBarsSession() {
        let station = AX25Address(call: "K0EPI", ssid: 3)
        var live = summary(.connected, destination: station, neighbor: station)
        live.requestedAlias = "EPINDB"
        var closing = NetRomCircuitSummary(id: live.id, destination: station, neighbor: station,
                                           state: .disconnecting, openedAt: live.openedAt)
        closing.requestedAlias = "EPINDB"

        for bar in ["EPINDB", "K0EPI-3", "epindb"] {
            XCTAssertTrue(NetRomCircuitSession.barSessionEnded(
                barDestination: bar, barIsNetRomSession: true, before: [live], after: []), "bar \(bar)")
            XCTAssertTrue(NetRomCircuitSession.barSessionEnded(
                barDestination: bar, barIsNetRomSession: true, before: [live], after: [closing]), "bar \(bar)")
        }
    }

    /// The compose bar shows the terminal's AX.25 session state. A link
    /// that only carried circuits is not the operator's session once no
    /// circuit rides it (issue 84).
    func testALinkLeftForTheNodeIsNotTheOperatorsSession() {
        let station = AX25Address(call: "K0EPI", ssid: 3)
        let riding = summary(.connected, destination: station, neighbor: station)
        let closing = summary(.disconnecting, destination: station, neighbor: station)
        let elsewhere = summary(.connected)

        XCTAssertFalse(NetRomCircuitSession.linkIsOperatorSession(
            carriesNetRom: true, peer: station, circuits: []))
        XCTAssertFalse(NetRomCircuitSession.linkIsOperatorSession(
            carriesNetRom: true, peer: station, circuits: [elsewhere]),
            "a circuit through another neighbor does not ride this link")
        XCTAssertTrue(NetRomCircuitSession.linkIsOperatorSession(
            carriesNetRom: true, peer: station, circuits: [riding]))
        XCTAssertTrue(NetRomCircuitSession.linkIsOperatorSession(
            carriesNetRom: true, peer: station, circuits: [closing]),
            "still closing: Disconnect stays until it is done")
        XCTAssertTrue(NetRomCircuitSession.linkIsOperatorSession(
            carriesNetRom: false, peer: station, circuits: []),
            "a plain AX.25 session is the operator's")
    }

    func testOnlyTheBarsOwnCircuitEndsIt() {
        let station = AX25Address(call: "K0EPI", ssid: 3)
        let live = summary(.connected, destination: station, neighbor: station)
        let other = summary(.connected)

        // Another station's circuit closing.
        XCTAssertFalse(NetRomCircuitSession.barSessionEnded(
            barDestination: "K0EPI-3", barIsNetRomSession: true, before: [live, other], after: [live]))
        // Still up.
        XCTAssertFalse(NetRomCircuitSession.barSessionEnded(
            barDestination: "K0EPI-3", barIsNetRomSession: true, before: [live], after: [live]))
        // A second circuit to the same station is still up.
        let second = summary(.connected, destination: station, neighbor: station)
        XCTAssertFalse(NetRomCircuitSession.barSessionEnded(
            barDestination: "K0EPI-3", barIsNetRomSession: true, before: [live, second], after: [second]))
        // The bar is not showing a NET/ROM session (an AX.25 link, or a
        // node-prompt relay, which has no circuit at all).
        XCTAssertFalse(NetRomCircuitSession.barSessionEnded(
            barDestination: "K0EPI-3", barIsNetRomSession: false, before: [live], after: []))
        // Nothing was up to begin with: a relay session's bar is left alone.
        XCTAssertFalse(NetRomCircuitSession.barSessionEnded(
            barDestination: "K0EPI-3", barIsNetRomSession: true, before: [], after: []))
    }

    // MARK: - Where typed text goes

    func testTextGoesToAnEstablishedCircuit() {
        let circuit = summary(.connected)
        let target = NetRomCircuitSession.sendTarget(
            activeRecordID: NetRomCircuitSession.recordID(for: circuit.id),
            circuits: [circuit])
        XCTAssertEqual(target, .circuit(circuit.id))
    }

    func testNoSelectionFallsBackToAX25() {
        XCTAssertEqual(
            NetRomCircuitSession.sendTarget(activeRecordID: nil, circuits: []),
            .ax25,
            "'All Traffic' must not swallow ordinary sends")
    }

    func testAX25SelectionStillUsesTheAX25Path() {
        let circuit = summary(.connected)
        XCTAssertEqual(
            NetRomCircuitSession.sendTarget(activeRecordID: "KB5YZB-7", circuits: [circuit]),
            .ax25,
            "an open circuit must not hijack a selected AX.25 session")
    }

    func testTextIsHeldWhileTheCircuitIsStillComingUp() {
        // The same reasoning as the relay handshake guard: the words are
        // meant for the far end, and there is nowhere to put them yet.
        let circuit = summary(.connecting)
        guard case let .circuitNotReady(reason) = NetRomCircuitSession.sendTarget(
            activeRecordID: NetRomCircuitSession.recordID(for: circuit.id),
            circuits: [circuit]) else {
            return XCTFail("a connecting circuit must not accept text")
        }
        XCTAssertTrue(reason.contains("COSCO"), "the reason names the station: \(reason)")
        XCTAssertTrue(reason.contains("still in the box"),
                      "and tells the operator their text was kept: \(reason)")
    }

    func testTextIsHeldWhileTheCircuitIsClosing() {
        let circuit = summary(.disconnecting)
        guard case let .circuitNotReady(reason) = NetRomCircuitSession.sendTarget(
            activeRecordID: NetRomCircuitSession.recordID(for: circuit.id),
            circuits: [circuit]) else {
            return XCTFail("a closing circuit must not accept text")
        }
        XCTAssertTrue(reason.contains("closing"), reason)
    }

    func testSelectingAClosedCircuitRecordExplainsItself() {
        // The record outlives the circuit in the picker, so the operator
        // can still read the transcript. Typing into it must not silently
        // fall through to AX.25 and transmit to the wrong place.
        let gone = NetRomCircuitSession.recordID(for: NetRomCircuitID())
        guard case let .circuitNotReady(reason) = NetRomCircuitSession.sendTarget(
            activeRecordID: gone, circuits: []) else {
            return XCTFail("a closed circuit record must not fall through to AX.25")
        }
        XCTAssertTrue(reason.contains("closed"), reason)
    }

    // MARK: - Picker wording

    func testStatusTextMatchesTheAX25Dialect() {
        XCTAssertEqual(NetRomCircuitSession.statusText(for: .connected), "Connected")
        XCTAssertEqual(NetRomCircuitSession.statusText(for: .disconnected), "Disconnected",
                       "'Clear Closed' keys off this exact string")
        XCTAssertEqual(NetRomCircuitSession.statusText(for: .connecting), "Connecting…")
        XCTAssertEqual(NetRomCircuitSession.statusText(for: .disconnecting), "Disconnecting…")
    }
}
