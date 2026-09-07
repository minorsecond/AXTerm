import XCTest
@testable import AXTerm

/// The words the status surfaces use for one radio or several.
///
/// The single-radio strings are pinned literally: an operator with one TNC
/// must see exactly what they saw before radios were a thing. The multi-radio
/// strings are pinned so the capsule, sidebar and menu bar cannot drift into
/// three different ways of counting.
final class RadioPresentationTests: XCTestCase {

    // MARK: - One radio: parity

    func testOneRadioKeepsTheCapsuleStringsItAlwaysHad() {
        XCTAssertEqual(RadioPresentation.capsuleLabel([.fixture(status: .connected)]),
                       "TNC: 192.168.3.218")
        XCTAssertEqual(RadioPresentation.capsuleLabel([.fixture(status: .connecting)]),
                       "TNC Connecting\u{2026}")
        XCTAssertEqual(RadioPresentation.capsuleLabel([.fixture(status: .disconnected)]),
                       "TNC Disconnected")
        XCTAssertEqual(RadioPresentation.capsuleLabel([.fixture(status: .failed)]),
                       "TNC Failed")
    }

    /// A serial TNC has no host. The capsule shows the device instead of a
    /// blank after the colon.
    func testASerialRadioShowsItsDeviceWhereAHostWouldGo() {
        let serial = RadioStatusSummary.fixture(
            status: .connected, host: "", port: nil, endpoint: "/dev/cu.usbserial-1420")
        XCTAssertEqual(RadioPresentation.capsuleLabel([serial]), "TNC: /dev/cu.usbserial-1420")
    }

    func testNoRadiosReadsAsDisconnected() {
        XCTAssertEqual(RadioPresentation.capsuleLabel([]), "TNC Disconnected")
        XCTAssertEqual(RadioPresentation.aggregateStatus([]), .disconnected)
    }

    // MARK: - Several radios

    func testSeveralRadiosAreCounted() {
        let a = RadioStatusSummary.fixture(id: "a", name: "Direwolf")
        let b = RadioStatusSummary.fixture(id: "b", name: "IC-705", status: .disconnected)
        XCTAssertEqual(RadioPresentation.capsuleLabel([a, .fixture(id: "b", name: "IC-705")]),
                       "Radios: 2 connected")
        XCTAssertEqual(RadioPresentation.capsuleLabel([a, b]), "Radios: 1 of 2")
    }

    /// With nothing up, the reason matters: still trying is not the same as
    /// gave up.
    func testNothingUpSaysWhy() {
        let down = RadioStatusSummary.fixture(id: "a", status: .disconnected)
        let trying = RadioStatusSummary.fixture(id: "b", status: .connecting)
        let failed = RadioStatusSummary.fixture(id: "c", status: .failed)
        XCTAssertEqual(RadioPresentation.capsuleLabel([down, trying]), "Radios Connecting\u{2026}")
        XCTAssertEqual(RadioPresentation.capsuleLabel([down, failed]), "Radios: 1 failed")
        XCTAssertEqual(RadioPresentation.capsuleLabel([down, .fixture(id: "d", status: .disconnected)]),
                       "Radios Disconnected")
    }

    /// The one dot that remains on single-dot surfaces: any working link
    /// counts as working; one still coming up outranks one that failed.
    func testAggregateStatusPrefersTheMostHopefulLink() {
        XCTAssertEqual(RadioPresentation.aggregateStatus([.failed, .connected]), .connected)
        XCTAssertEqual(RadioPresentation.aggregateStatus([.failed, .connecting]), .connecting)
        XCTAssertEqual(RadioPresentation.aggregateStatus([.disconnected, .failed]), .failed)
        XCTAssertEqual(RadioPresentation.aggregateStatus([.disconnected]), .disconnected)
    }

    func testTintFollowsStatus() {
        XCTAssertEqual(RadioPresentation.tint(for: .connected), .connected)
        XCTAssertEqual(RadioPresentation.tint(for: .connecting), .connecting)
        XCTAssertEqual(RadioPresentation.tint(for: .failed), .failed)
        XCTAssertEqual(RadioPresentation.tint(for: .disconnected), .idle)
    }

    // MARK: - Explaining a dot

    /// Enough to act on without opening anything: which radio, how it is
    /// doing, where the link goes, who it is on the air.
    func testDotHelpNamesRadioLinkAndCallsign() {
        XCTAssertEqual(RadioPresentation.dotHelp(.fixture(name: "IC-705", callsign: "K0EPI-1",
                                                          host: "", port: nil,
                                                          endpoint: "/dev/cu.usbserial-1420")),
                       "IC-705: Connected \u{b7} /dev/cu.usbserial-1420 \u{b7} K0EPI-1")
    }

    /// A failure says what failed; a working link does not repeat an old
    /// error.
    func testDotHelpCarriesTheErrorOnlyWhenFailed() {
        let failed = RadioStatusSummary.fixture(name: "IC-705", status: .failed,
                                                lastError: "Connection refused")
        XCTAssertEqual(RadioPresentation.dotHelp(failed),
                       "IC-705: Failed \u{b7} 192.168.3.218:8001 \u{b7} K0EPI-7 \u{2014} Connection refused")
        let recovered = RadioStatusSummary.fixture(name: "IC-705", status: .connected,
                                                   lastError: "Connection refused")
        XCTAssertFalse(RadioPresentation.dotHelp(recovered).contains("refused"))
    }

    // MARK: - Sidebar header

    func testSidebarTitleCountsOnlyWhatIsNotObvious() {
        XCTAssertEqual(RadioPresentation.sidebarTitle(total: 2, connected: 2, hidden: 0), "Radios (2)")
        XCTAssertEqual(RadioPresentation.sidebarTitle(total: 2, connected: 1, hidden: 0),
                       "Radios (1 of 2 connected)")
        XCTAssertEqual(RadioPresentation.sidebarTitle(total: 3, connected: 3, hidden: 1),
                       "Radios (3) \u{b7} 1 hidden")
    }
}
