import XCTest
@testable import AXTerm

/// What the packet table says about its own scope.
///
/// The Packets page is the only view in this app that is not an inference —
/// Routes, Nodes, the map and the coverage rings all derive their claims
/// from these frames. So "I looked at the packets and it wasn't there" has
/// to be trustworthy, which means a filter must never drop rows quietly.
///
/// These controls existed and were honoured by `PacketFilter` the whole
/// time; nothing presented the popover, so `showS` was permanently true and
/// two thirds of the table was link-layer chatter with no payload.
final class PacketFilterSummaryTests: XCTestCase {

    func testAnUnfilteredTableSaysSoAndOffersNothingToClear() {
        let filters = PacketFilters()
        XCTAssertTrue(filters.isDefault)
        XCTAssertNil(filters.restrictionSummary)
        XCTAssertEqual(filters.statusLine(shown: 24_353, total: 24_353, station: nil),
                       "24,353 frames")
    }

    /// The count alone would say something is missing without saying what.
    func testAHiddenFrameClassIsNamed() {
        var filters = PacketFilters()
        filters.showS = false
        XCTAssertEqual(filters.restrictionSummary, "no S frames")
        XCTAssertEqual(filters.statusLine(shown: 16_174, total: 24_353, station: nil),
                       "16,174 of 24,353 frames · no S frames")
    }

    func testSeveralHiddenClassesAreListedTogether() {
        var filters = PacketFilters()
        filters.showS = false
        filters.showU = false
        XCTAssertEqual(filters.restrictionSummary, "no S/U frames")
    }

    /// The sidebar's station filter hides rows exactly as effectively as
    /// these switches, so it belongs in the same sentence.
    func testTheStationFilterIsPartOfTheSameStatement() {
        XCTAssertEqual(
            PacketFilters().statusLine(shown: 322, total: 24_353, station: "KB5YZB-7"),
            "322 of 24,353 frames · from KB5YZB-7")
    }

    /// Payload-only admits I frames and UI frames carrying text and nothing
    /// else, so the S and U switches stop meaning anything while it is on.
    /// Reporting "no S/U frames" alongside it would describe switches that
    /// are not doing the hiding.
    func testPayloadOnlySupersedesTheFrameTypeSwitches() {
        var filters = PacketFilters()
        filters.payloadOnly = true
        filters.showS = false
        XCTAssertFalse(filters.frameTypeSwitchesApply)
        XCTAssertEqual(filters.restrictionSummary, "payload only")
    }

    /// Under payload-only, I and UI are the two switches still doing
    /// something, so those stay named.
    func testPayloadOnlyStillNamesTheSwitchesThatApply() {
        var filters = PacketFilters()
        filters.payloadOnly = true
        filters.showUI = false
        XCTAssertEqual(filters.restrictionSummary, "payload only · no UI frames")
    }

    /// An empty table from a quiet channel and an empty table from a
    /// contradictory filter look identical, and only one of them is the
    /// operator's mistake.
    func testASettingThatCanNeverMatchIsRecognised() {
        var all = PacketFilters()
        all.showUI = false; all.showI = false; all.showS = false; all.showU = false
        XCTAssertTrue(all.admitsNothing)

        var payload = PacketFilters()
        payload.payloadOnly = true
        payload.showI = false
        payload.showUI = false
        XCTAssertTrue(payload.admitsNothing, "payload-only with both payload classes off")

        // Payload-only with S and U off is ordinary: those were already
        // excluded, and I and UI still come through.
        var ordinary = PacketFilters()
        ordinary.payloadOnly = true
        ordinary.showS = false
        ordinary.showU = false
        XCTAssertFalse(ordinary.admitsNothing)

        XCTAssertFalse(PacketFilters().admitsNothing)
    }

    func testPinnedOnlyIsNamedAlongsideTheRest() {
        var filters = PacketFilters()
        filters.onlyPinned = true
        filters.showS = false
        XCTAssertEqual(filters.restrictionSummary, "no S frames · pinned only")
    }

    /// One frame is one frame.
    func testTheUnfilteredCountReadsNaturallyAtOne() {
        XCTAssertEqual(PacketFilters().statusLine(shown: 1, total: 1, station: nil), "1 frame")
    }
}
