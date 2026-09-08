import XCTest
@testable import AXTerm

/// The console's per-radio filter: received traffic is attributed to its
/// radio, our own transmissions and system notices always show, and an
/// unattributed received line falls back to the primary (as the Packets table
/// and map do) so it never slips past the filter.
final class ConsoleLineRadioFilterTests: XCTestCase {

    private let me = "K0EPI"
    private let uhf = RadioID(rawValue: "uhf")

    private func packet(from: String, radio: RadioID?) -> ConsoleLine {
        ConsoleLine(kind: .packet, from: from, to: "CQ", text: "hi", radioID: radio)
    }

    func testNothingHiddenShowsEverything() {
        let line = packet(from: "W0UHF", radio: uhf)
        XCTAssertTrue(line.passesRadioFilter(hidden: [], myCallsign: me))
    }

    func testAHiddenRadiosReceivedLineIsHidden() {
        let line = packet(from: "W0UHF", radio: uhf)
        XCTAssertFalse(line.passesRadioFilter(hidden: [uhf], myCallsign: me))
    }

    func testAVisibleRadiosReceivedLineStays() {
        let line = packet(from: "W0ABC", radio: .primary)
        XCTAssertTrue(line.passesRadioFilter(hidden: [uhf], myCallsign: me))
    }

    func testAnUnattributedReceivedLineFollowsThePrimary() {
        // Legacy / pre-radio line: treated as the primary radio's, matching
        // the Packets table — so hiding the primary hides it.
        let line = packet(from: "W0ABC", radio: nil)
        XCTAssertFalse(line.passesRadioFilter(hidden: [.primary], myCallsign: me))
        XCTAssertTrue(line.passesRadioFilter(hidden: [uhf], myCallsign: me))
    }

    func testOurOwnTransmissionAlwaysShows() {
        // From us, no radio — a TX echo. It must not vanish when we hide a radio.
        let line = packet(from: me, radio: nil)
        XCTAssertTrue(line.passesRadioFilter(hidden: [.primary], myCallsign: me))
        XCTAssertTrue(line.passesRadioFilter(hidden: [uhf], myCallsign: me))
    }

    func testSystemAndErrorLinesAlwaysShow() {
        let system = ConsoleLine(kind: .system, text: "connected", radioID: nil)
        let error = ConsoleLine(kind: .error, text: "link failed", radioID: nil)
        XCTAssertTrue(system.passesRadioFilter(hidden: [.primary], myCallsign: me))
        XCTAssertTrue(error.passesRadioFilter(hidden: [.primary], myCallsign: me))
    }

    func testAStampedSessionLineHonoursTheFilter() {
        // Session chat is now attributed to the session's radio.
        let line = ConsoleLine(kind: .packet, from: "W0UHF", to: me, text: "hello", radioID: uhf)
        XCTAssertFalse(line.passesRadioFilter(hidden: [uhf], myCallsign: me))
    }
}
