import XCTest
@testable import AXTerm

/// Which overheard destinations name a station worth probing.
///
/// `PingProber` transmits — an XID, and a DISC if that goes unanswered — so
/// every name that reaches its candidate list costs airtime on a shared
/// channel. The list was fed from the destination of every frame not
/// addressed to us, and in AX.25 only *connected mode* puts a station's
/// address there.
///
/// A UI frame's destination is not an address at all. APRS puts a tocall in
/// it (APRS 1.01 ch.5) — `APMI04`, `APRX29`, `APDR17` — and Mic-E overloads
/// it with the latitude, the message bits and the N/S and E/W signs (ch.10),
/// which is why `S8RVTQ` and `SYTPZZ` appear there. All of them pass a
/// callsign shape test, because they are six alphanumerics with a digit in
/// them; nothing about their spelling says they are data.
///
/// From the operator's log of 2026-09-09: a Mic-E position from NK7W-9 to
/// `S8RVTQ` was overheard, and seconds later AXTerm sent an XID and then a
/// DISC to `S8RVTQ` — a callsign that cannot exist.
final class OverheardCalleeTests: XCTestCase {

    private func decode(_ control: UInt8) -> AX25ControlFieldDecoded {
        AX25ControlFieldDecoder.decode(control: control, controlByte1: nil)
    }

    /// The frame from the log. `0x03` is UI.
    func testAMicEDestinationIsNotAStation() {
        let ui = decode(0x03)
        XCTAssertEqual(ui.uType, .UI, "the frame NK7W-9 sent")
        XCTAssertFalse(SessionCoordinator.addressesAStation(ui),
                       "S8RVTQ is NK7W-9's latitude, not a station to probe")
    }

    /// And the shape test cannot save us. It requires a digit and a letter,
    /// which rejects some Mic-E destinations *by accident* and admits every
    /// one that happens to encode a latitude containing a digit — along with
    /// the whole APRS tocall space, which is mostly digits by construction.
    /// An accident that catches half the cases is not a rule, which is why
    /// this has to be decided by the frame type.
    func testTheShapeTestCannotDecide() {
        for tocall in ["S8RVTQ", "APMI04", "APRX29", "APDR17", "APAT51", "APBT62"] {
            XCTAssertTrue(CallsignQuery.isPlausible(tocall),
                          "\(tocall) passes a callsign shape test, so shape admits it")
        }
        // Only these slip through, and only because they have no digit.
        for digitless in ["SYTPZZ", "EAAQXP", "TPRTTS"] {
            XCTAssertFalse(CallsignQuery.isPlausible(digitless),
                           "\(digitless) is rejected for having no digit, not for being data")
        }
    }

    /// Connected mode is where a destination really is a station: somebody
    /// asked it for a link, or is running one with it.
    func testConnectedModeDestinationsAreStations() {
        XCTAssertTrue(SessionCoordinator.addressesAStation(decode(0x2F)), "SABM")
        XCTAssertTrue(SessionCoordinator.addressesAStation(decode(0x43)), "DISC")
        XCTAssertTrue(SessionCoordinator.addressesAStation(decode(0x63)), "UA")
        XCTAssertTrue(SessionCoordinator.addressesAStation(decode(0x0F)), "DM")
        XCTAssertTrue(SessionCoordinator.addressesAStation(decode(0xAF)), "XID")
        XCTAssertTrue(SessionCoordinator.addressesAStation(decode(0x00)), "I frame")
        XCTAssertTrue(SessionCoordinator.addressesAStation(decode(0x01)), "RR")
    }

    // MARK: - The rule where it is applied

    /// The rule above is worth nothing unless the ingestion path uses it.
    /// This drives the frame from the log through the real handler and asks
    /// the real candidate list.
    @MainActor
    private func candidates(after packet: Packet) -> [String] {
        let coordinator = SessionCoordinator()
        coordinator.localCallsign = "K0EPI-7"
        coordinator.handleIncomingPacket(packet)
        return coordinator.pingCandidates().map(\.call)
    }

    @MainActor
    func testOverhearingAMicEPositionAddsNoProbeCandidate() {
        // NK7W-9 > S8RVTQ, the exact frame from 2026-09-09.
        let micE = Packet(from: AX25Address(call: "NK7W", ssid: 9),
                          to: AX25Address(call: "S8RVTQ", ssid: 0),
                          frameType: .ui, control: 0x03, pid: 0xF0,
                          info: Data([0x60, 0x71, 0x29, 0x7f, 0x1c, 0x1d, 0x60, 0x3e]))
        XCTAssertFalse(candidates(after: micE).contains("S8RVTQ"),
                       "AXTerm would transmit an XID, and then a DISC, to a latitude")
    }

    /// An APRS beacon's tocall is no better.
    @MainActor
    func testOverhearingAnAPRSBeaconAddsNoProbeCandidate() {
        let beacon = Packet(from: AX25Address(call: "KK0X", ssid: 10),
                            to: AX25Address(call: "APMI04", ssid: 0),
                            frameType: .ui, control: 0x03, pid: 0xF0,
                            info: Data("@080030z3934.15N/10455.05W-".utf8))
        XCTAssertFalse(candidates(after: beacon).contains("APMI04"))
    }

    /// And the signal this was built to collect still arrives: somebody
    /// asking a station for a link says that station is worth asking too.
    @MainActor
    func testOverhearingAConnectRequestStillAddsTheCandidate() {
        let sabm = Packet(from: AX25Address(call: "N0CALL", ssid: 1),
                          to: AX25Address(call: "W0ARP", ssid: 10),
                          frameType: .u, control: 0x2F, pid: nil, info: Data())
        XCTAssertTrue(candidates(after: sabm).contains("W0ARP-10"),
                      "a station somebody is connecting to is a real station")
    }

    /// A U frame we cannot classify is not evidence of a link either. TEST
    /// frames land here, and they are connectionless.
    func testAnUnclassifiedUFrameIsNotEvidence() {
        let test = decode(0xE3)          // TEST, which is connectionless
        XCTAssertEqual(test.frameClass, .U)
        XCTAssertEqual(test.uType, .UNKNOWN)
        XCTAssertFalse(SessionCoordinator.addressesAStation(test))
    }
}
