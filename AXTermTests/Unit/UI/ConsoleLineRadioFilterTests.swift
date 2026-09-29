import XCTest
@testable import AXTerm

/// The console's per-radio filter.
///
/// Three rules: errors always show, app notices always show, and everything
/// else belongs to its radios and hides with them.
///
/// What this replaced showed *every* system notice whatever was hidden — so a
/// two-radio station with one switched off still read that radio's connects,
/// disconnects, transmissions and beacons — and showed our own frames on a
/// hidden radio, which the Packets table had always dropped. The console and
/// the packet table disagreed about the same sidebar switch.
final class ConsoleLineRadioFilterTests: XCTestCase {

    private let me = "K0EPI"
    private let uhf = RadioID(rawValue: "uhf")

    private func packet(from: String, radio: RadioID?) -> ConsoleLine {
        ConsoleLine.packet(from: from, to: "CQ", text: "hi", radioID: radio)
    }

    // MARK: - Received traffic

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

    // MARK: - Our own traffic

    /// Changed deliberately. Our transmissions used to be exempt, which put
    /// this view at odds with `PacketFilter` — that has always hidden them
    /// with their radio — and left the operator half a conversation: hide a
    /// radio and you saw what you sent on it but not the answer.
    func testOurOwnTransmissionHidesWithItsRadio() {
        let line = packet(from: me, radio: uhf)
        XCTAssertFalse(line.passesRadioFilter(hidden: [uhf], myCallsign: me))
        XCTAssertTrue(line.passesRadioFilter(hidden: [.primary], myCallsign: me))
    }

    func testAnUnattributedTransmissionFollowsThePrimaryLikeAnyOtherLine() {
        let line = packet(from: me, radio: nil)
        XCTAssertFalse(line.passesRadioFilter(hidden: [.primary], myCallsign: me))
        XCTAssertTrue(line.passesRadioFilter(hidden: [uhf], myCallsign: me))
    }

    // MARK: - Notices

    /// An app notice belongs to no radio, so no radio filter matches it.
    func testAnAppNoticeAlwaysShows() {
        let line = ConsoleLine.system("Database migrated to v14")
        XCTAssertTrue(line.passesRadioFilter(hidden: [.primary, uhf], myCallsign: me))
    }

    /// A notice about a radio hides with it. This is the case that started it:
    /// "Connected to ham-pi:8001" is Direwolf's, and was showing with Direwolf
    /// switched off.
    func testANoticeAboutAHiddenRadioIsHidden() {
        let line = ConsoleLine.system("Connected to ham-pi:8001", radios: [uhf])
        XCTAssertFalse(line.passesRadioFilter(hidden: [uhf], myCallsign: me))
        XCTAssertTrue(line.passesRadioFilter(hidden: [.primary], myCallsign: me))
    }

    /// A shared TNC carries several radios on one byte stream, so that link
    /// coming up is news for all of them — and the line survives while any one
    /// of them is still visible.
    func testASharedLinksNoticeSurvivesWhileAnyOfItsRadiosIsVisible() {
        let line = ConsoleLine.system("Connected to ham-pi:8001", radios: [uhf, .primary])
        XCTAssertTrue(line.passesRadioFilter(hidden: [uhf], myCallsign: me))
        XCTAssertTrue(line.passesRadioFilter(hidden: [.primary], myCallsign: me))
        XCTAssertFalse(line.passesRadioFilter(hidden: [uhf, .primary], myCallsign: me))
    }

    func testAnUnnamedRadiosNoticeFollowsThePrimary() {
        let line = ConsoleLine.system("Frame sent successfully", radios: [])
        XCTAssertFalse(line.passesRadioFilter(hidden: [.primary], myCallsign: me))
        XCTAssertTrue(line.passesRadioFilter(hidden: [uhf], myCallsign: me))
    }

    // MARK: - Errors

    /// Hiding a radio is a view filter, not an operational disable: the
    /// station is on the air with our callsign whether we are looking at that
    /// radio or not. A link that drops, a PTT refused, a port lost — those
    /// reach the operator from a hidden radio exactly as from a visible one.
    func testAnErrorAlwaysShows() {
        let error = ConsoleLine.error("Direwolf: connection refused")
        XCTAssertTrue(error.passesRadioFilter(hidden: [.primary, uhf], myCallsign: me))
    }

    // MARK: - The badge

    /// The per-line radio badge names a radio only when there is one to name.
    func testTheBadgeNamesASingleRadioAndNothingElse() {
        XCTAssertEqual(ConsoleLine.system("x", radios: [uhf]).radioID, uhf)
        XCTAssertNil(ConsoleLine.system("x", radios: [uhf, .primary]).radioID,
                     "a shared link has no one radio to name")
        XCTAssertNil(ConsoleLine.system("x").radioID)
        XCTAssertNil(ConsoleLine.system("x", radios: []).radioID)
    }

    // MARK: - Round trip

    /// A reloaded transcript hides with the same switches a live one does.
    func testTheAttributionSurvivesAReload() {
        for subject: ConsoleLine.Subject in [.app, .radios([uhf]), .radios([uhf, .primary]), .unnamedRadio] {
            let stored: [String]?
            switch subject {
            case .app: stored = nil
            case .radios(let ids): stored = ids.map(\.rawValue).sorted()
            case .unnamedRadio: stored = []
            }
            XCTAssertEqual(ConsoleLine.Subject(stored: stored), subject, "\(subject)")
        }
    }

    func testAStampedSessionLineHonoursTheFilter() {
        // Session chat is attributed to the session's radio.
        let line = ConsoleLine.packet(from: "W0UHF", to: me, text: "hello", radioID: uhf)
        XCTAssertFalse(line.passesRadioFilter(hidden: [uhf], myCallsign: me))
    }
}
