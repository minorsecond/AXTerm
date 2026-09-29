import XCTest
@testable import AXTerm

/// Which addresses this station accepts calls on.
///
/// The point of the registry: a node runs several services on one radio and
/// callers pick one by the callsign they dial. Frames not addressed to a
/// registered address are dropped before the session layer, so a service that
/// does not register here is unreachable however carefully it is configured —
/// which is exactly the failure this was written after.
@MainActor
final class StationServiceAddressTests: XCTestCase {

    private func manager(_ callsign: String = "K0EPI-7") -> AX25SessionManager {
        AX25SessionManager(localCallsign: CallsignNormalizer.toAddress(callsign))
    }

    private func address(_ display: String) -> AX25Address {
        CallsignNormalizer.toAddress(display)
    }

    func testTheStationCallsignIsAlwaysAnswered() {
        XCTAssertTrue(manager().answers(address("K0EPI-7")))
    }

    func testAnUnrelatedAddressIsNotAnswered() {
        XCTAssertFalse(manager().answers(address("W0ARP-10")))
    }

    /// Before the registry, this was the bug: a mailbox given its own SSID
    /// never received the call at all.
    func testARegisteredServiceAddressIsAnswered() {
        let sut = manager("K0EPI-7")
        XCTAssertFalse(sut.answers(address("K0EPI-2")))

        sut.setServiceAddress(address("K0EPI-2"), for: "bbs")
        XCTAssertTrue(sut.answers(address("K0EPI-2")))
        // And the station callsign still is.
        XCTAssertTrue(sut.answers(address("K0EPI-7")))
    }

    func testTwoServicesAnswerOnTheirOwnAddresses() {
        let sut = manager("K0EPI-7")
        sut.setServiceAddress(address("K0EPI-2"), for: "bbs")
        sut.setServiceAddress(address("K0EPI-1"), for: "winlink.p2p")

        XCTAssertTrue(sut.answers(address("K0EPI-2")))
        XCTAssertTrue(sut.answers(address("K0EPI-1")))
        XCTAssertFalse(sut.answers(address("K0EPI-3")))
    }

    /// Keyed by service so editing an SSID moves it rather than adding one.
    /// A stale address left answering is a station replying as a service that
    /// has moved.
    func testReRegisteringMovesTheAddressRatherThanAddingOne() {
        let sut = manager("K0EPI-7")
        sut.setServiceAddress(address("K0EPI-2"), for: "bbs")
        sut.setServiceAddress(address("K0EPI-3"), for: "bbs")

        XCTAssertFalse(sut.answers(address("K0EPI-2")), "the old SSID must stop answering")
        XCTAssertTrue(sut.answers(address("K0EPI-3")))
    }

    func testWithdrawingAnAddressStopsAnsweringIt() {
        let sut = manager("K0EPI-7")
        sut.setServiceAddress(address("K0EPI-2"), for: "bbs")
        sut.setServiceAddress(nil, for: "bbs")
        XCTAssertFalse(sut.answers(address("K0EPI-2")))
    }

    /// SSIDs are part of the address: a service on -2 must not answer -3.
    func testSSIDsAreDistinct() {
        let sut = manager("K0EPI-7")
        sut.setServiceAddress(address("K0EPI-2"), for: "bbs")
        XCTAssertFalse(sut.answers(address("K0EPI")))
        XCTAssertFalse(sut.answers(address("K0EPI-3")))
    }

    func testAnsweredAddressesListsTheStationFirst() {
        let sut = manager("K0EPI-7")
        sut.setServiceAddress(address("K0EPI-2"), for: "bbs")
        XCTAssertEqual(sut.answeredAddresses.map(\.display), ["K0EPI-7", "K0EPI-2"])
    }
}
