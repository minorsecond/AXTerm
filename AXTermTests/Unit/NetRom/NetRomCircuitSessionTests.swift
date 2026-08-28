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
