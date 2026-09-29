import XCTest
@testable import AXTerm

/// Each radio operates as its own address.
///
/// Two radios on one licence are two stations on the air; a remote station
/// dials one of them. The session layer keeps one address per radio, opens
/// outbound links under it, answers calls to it, and — when a call to an
/// address only one radio uses is heard by another radio on the same
/// frequency — hands the call to the radio it was for.
@MainActor
final class RadioAddressTests: XCTestCase {

    private let station = AX25Address(call: "K0EPI", ssid: 7)
    private let uhfCall = AX25Address(call: "K0EPI", ssid: 1)
    private let uhf = RadioID(rawValue: "uhf")
    private let peer = AX25Address(call: "PEER", ssid: 1)

    private func manager() -> AX25SessionManager {
        let m = AX25SessionManager(localCallsign: station)
        m.setLocalAddresses([uhf: uhfCall])
        return m
    }

    // MARK: - The session manager

    func testARadioWithoutItsOwnAddressUsesTheStationCallsign() {
        let m = manager()
        XCTAssertEqual(m.localAddress(for: .primary), station)
        XCTAssertEqual(m.localAddress(for: uhf), uhfCall)
    }

    func testAnOutboundSessionOpensUnderTheRadiosAddress() {
        let m = manager()
        XCTAssertEqual(m.session(for: peer, radio: uhf).localAddress, uhfCall)
        XCTAssertEqual(m.session(for: peer, radio: .primary).localAddress, station)
        let sabm = m.connect(to: peer, path: DigiPath(), radio: uhf)
        XCTAssertEqual(sabm?.source, uhfCall)
        XCTAssertEqual(sabm?.radio, uhf)
    }

    func testTheStationAnswersToEveryRadiosAddress() {
        let m = manager()
        XCTAssertTrue(m.answers(station))
        XCTAssertTrue(m.answers(uhfCall))
        XCTAssertFalse(m.answers(AX25Address(call: "K0EPI", ssid: 2)))
        XCTAssertEqual(m.answeredAddresses.map(\.display), ["K0EPI-7", "K0EPI-1"])
    }

    /// The DM for a stranger's poll comes from the address the radio uses.
    func testADMLeavesFromTheRadiosAddress() {
        let m = manager()
        let dm = m.handleInboundRR(from: peer, path: DigiPath(), radio: uhf, nr: 0, pf: true, isCommand: true)
        XCTAssertEqual(dm?.source, uhfCall)
        XCTAssertEqual(dm?.radio, uhf)
    }

    /// Changing one radio's address ends that radio's sessions and no others:
    /// a session is bound to the address it opened under.
    func testChangingOneRadiosAddressEndsOnlyItsSessions() {
        let m = manager()
        _ = m.connect(to: peer, path: DigiPath(), radio: uhf)
        _ = m.connect(to: peer, path: DigiPath(), radio: .primary)
        m.setLocalAddresses([uhf: AX25Address(call: "K0EPI", ssid: 3)])
        XCTAssertNil(m.existingSession(for: peer, path: DigiPath(), radio: uhf))
        XCTAssertNotNil(m.existingSession(for: peer, path: DigiPath(), radio: .primary))
        XCTAssertEqual(m.localAddress(for: uhf).ssid, 3)
    }

    func testSettingTheSameAddressesAgainChangesNothing() {
        let m = manager()
        _ = m.connect(to: peer, path: DigiPath(), radio: uhf)
        m.setLocalAddresses([uhf: uhfCall])
        XCTAssertNotNil(m.existingSession(for: peer, path: DigiPath(), radio: uhf))
    }
}
