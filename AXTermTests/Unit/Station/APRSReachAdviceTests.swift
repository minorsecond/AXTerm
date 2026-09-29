import XCTest
@testable import AXTerm

/// Asking a station at a reach that can reach it.
///
/// 2026-09-09, K0EPI-7's own channel: six stations pinged, three of which
/// could not have received the query. Every transmitted frame went out with
/// no digipeater path, while SIMLA and KF0YKI-9 had only ever been heard
/// *through* a digipeater and AD1CT-4 had never been heard at all. The
/// evidence was already in the station list.
final class APRSReachAdviceTests: XCTestCase {

    // MARK: - The rule

    func testOneDirectReceptionMeansItIsInEarshot() {
        XCTAssertEqual(APRSReachAdvice.advise(direct: 1, digipeated: 0), .inEarshot)
        // The case the wording of the rule turns on: heard direct once and
        // relayed fifty times since is still a station with a direct path.
        XCTAssertEqual(APRSReachAdvice.advise(direct: 1, digipeated: 50), .inEarshot)
    }

    func testRelayedOnlyMeansAskOverThePath() {
        let advice = APRSReachAdvice.advise(direct: 0, digipeated: 8)   // KF0YKI-9
        XCTAssertEqual(advice, .viaDigipeaterOnly)
        XCTAssertEqual(advice.suggestedReach, .wide)
        XCTAssertTrue(advice.disagrees(with: .direct),
                      "asking it direct is the mistake this exists to catch")
    }

    /// Never heard is evidence against expecting an answer, and evidence for
    /// no reach at all — so the operator's own choice stands.
    func testNeverHeardSuggestsNoReachButDoesWarn() {
        let advice = APRSReachAdvice.advise(direct: 0, digipeated: 0)    // AD1CT-4
        XCTAssertEqual(advice, .neverHeard)
        XCTAssertNil(advice.suggestedReach)
        XCTAssertFalse(advice.disagrees(with: .direct), "no suggestion cannot disagree")
        XCTAssertFalse(advice.disagrees(with: .wide))
        XCTAssertNotNil(advice.caution)
    }

    func testAStationInEarshotIsNotWarnedAbout() {
        XCTAssertNil(APRSReachAdvice.advise(direct: 5, digipeated: 0).caution)
        XCTAssertFalse(APRSReachAdvice.advise(direct: 5, digipeated: 0).disagrees(with: .direct))
    }

    // MARK: - The evidence behind it

    private func packet(_ from: String, via: [AX25Address] = [], at: TimeInterval = 1) -> Packet {
        Packet(timestamp: Date(timeIntervalSince1970: at),
               from: AX25Address(call: from), to: AX25Address(call: "APRS"), via: via,
               frameType: .ui, control: 0x03, info: Data("!x".utf8),
               rawAx25: Data([0x01]), radioID: .primary)
    }

    /// An unconsumed `WIDE1-1` in the path is not a digipeat: the frame
    /// arrived before anything repeated it. Only a hop marked used counts,
    /// which is exactly what `heardVia` keeps.
    func testAnUnusedPathIsStillADirectReception() {
        var tracker = StationTracker()
        tracker.update(with: packet("K0EPI-4", via: [AX25Address(call: "WIDE1", ssid: 1)]))
        let station = tracker.stations.first { $0.call == "K0EPI-4" }!
        XCTAssertEqual(station.directCount, 1)
        XCTAssertEqual(station.digipeatedCount, 0)
        XCTAssertEqual(station.reachAdvice, .inEarshot)
    }

    func testAUsedHopIsADigipeatedReception() {
        var tracker = StationTracker()
        tracker.update(with: packet("KF0YKI-9",
                                    via: [AX25Address(call: "WQ8M", ssid: 9, repeated: true)]))
        let station = tracker.stations.first { $0.call == "KF0YKI-9" }!
        XCTAssertEqual(station.directCount, 0)
        XCTAssertEqual(station.digipeatedCount, 1)
        XCTAssertEqual(station.reachAdvice, .viaDigipeaterOnly)
    }

    /// The omission that would make the whole feature lie for the first
    /// minutes of every launch: the station list is rebuilt from the packet
    /// log, and a rebuild that skipped these counters would report the entire
    /// channel as never heard.
    func testARebuildFromTheLogFillsTheCountersToo() {
        var tracker = StationTracker()
        tracker.rebuild(from: [
            packet("K0EPI-4", at: 1),
            packet("K0EPI-4", at: 2),
            packet("KF0YKI-9", via: [AX25Address(call: "WQ8M", ssid: 9, repeated: true)], at: 3),
        ])
        let mine = tracker.stations.first { $0.call == "K0EPI-4" }!
        XCTAssertEqual(mine.directCount, 2)
        XCTAssertEqual(mine.reachAdvice, .inEarshot)

        let far = tracker.stations.first { $0.call == "KF0YKI-9" }!
        XCTAssertEqual(far.digipeatedCount, 1)
        XCTAssertEqual(far.reachAdvice, .viaDigipeaterOnly)
    }

    // MARK: - What the operator is told

    /// An override the operator did not ask for has to announce itself. This
    /// is the sentence that stops "I picked direct and it went out wide" from
    /// being a silent surprise.
    func testAnOverriddenReachSaysSoInTheHelp() {
        let text = StationsMapView.pingHelp(
            label: "KF0YKI-9", reach: .wide,
            advice: .viaDigipeaterOnly, selected: .direct)
        XCTAssertTrue(text.contains("Digipeated on this radio's APRS path"), text)
        XCTAssertTrue(text.contains("Only ever heard through a digipeater"), text)
    }

    func testAnUnheardStationIsFlaggedEvenWithoutAnOverride() {
        let text = StationsMapView.pingHelp(
            label: "AD1CT-4", reach: .direct, advice: .neverHeard, selected: .direct)
        XCTAssertTrue(text.contains("Never heard on this radio"), text)
    }

    /// The ordinary case stays quiet.
    func testAStationInEarshotGetsNoExtraSentence() {
        let text = StationsMapView.pingHelp(
            label: "K0EPI-4", reach: .direct, advice: .inEarshot, selected: .direct)
        XCTAssertFalse(text.lowercased().contains("never heard"), text)
        XCTAssertFalse(text.lowercased().contains("digipeater"), text)
    }

    /// A station in the log that we have never heard from at all — the query
    /// went to a callsign scraped from someone else's path.
    func testAStationWeHaveNeverHeardHasNoEvidence() {
        var tracker = StationTracker()
        tracker.rebuild(from: [packet("K0EPI-4", at: 1)])
        XCTAssertNil(tracker.stations.first { $0.call == "AD1CT-4" },
                     "AD1CT-4 was never heard; the map's advice falls back to .neverHeard")
    }
}
