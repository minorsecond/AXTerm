import XCTest
@testable import AXTerm

/// The stand-down repeat: that it lands, and that it cannot kill the wrong
/// thing on its way.
final class APRSObjectKillRepeatTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_757_419_200)   // 091200z

    private func report(_ info: String) throws -> APRSObjectReport {
        try XCTUnwrap(APRSObjectReport.parse(info: Data(info.utf8)))
    }

    /// A live object under some name, as heard from `station`.
    private func live(_ name: String, from station: String) throws -> APRSObjectStore.Placed {
        var store = APRSObjectStore()
        let info = APRSObjectReport.objectInfo(
            name: name, live: true, latitude: 39.6, longitude: -104.7,
            symbolTable: "/", symbolCode: "-", at: epoch)
        store.record(try report(info), from: station, at: epoch)
        return try XCTUnwrap(store.live(now: epoch).first)
    }

    // MARK: - The wire constraint

    /// The reason the ladder starts at a minute. An object timestamp carries
    /// minutes and no seconds, so a sub-minute repeat is byte-identical to the
    /// frame before it and every digipeater's dedupe drops it.
    ///
    /// Falsify by putting anything under 60 into the ladder.
    func testRepeatsNeverEncodeToTheSameFrame() {
        var elapsed: TimeInterval = 0
        var frames: [String] = [APRSObjectReport.killInfo(
            name: "ROADCLOSE", latitude: 39.6, longitude: -104.7,
            symbolTable: "/", symbolCode: "-", at: epoch)]
        for delay in APRSObjectKillRepeat.ladder {
            elapsed += delay
            frames.append(APRSObjectReport.killInfo(
                name: "ROADCLOSE", latitude: 39.6, longitude: -104.7,
                symbolTable: "/", symbolCode: "-",
                at: epoch.addingTimeInterval(elapsed)))
        }
        XCTAssertEqual(Set(frames).count, frames.count,
                       "two repeats encode to the same bytes, so a digipeater "
                       + "will treat the second as a duplicate and drop it: \(frames)")
    }

    /// Bounded, and in that order — a ladder that shortened would spend more
    /// airtime the longer it went on.
    func testTheLadderDecaysAndStops() {
        let ladder = APRSObjectKillRepeat.ladder
        XCTAssertFalse(ladder.isEmpty)
        XCTAssertEqual(ladder, ladder.sorted(), "the gaps should widen, not narrow")
        XCTAssertLessThanOrEqual(ladder.reduce(0, +), 15 * 60,
                                 "a stand-down should be over inside a quarter hour")
    }

    // MARK: - What abandons a repeat

    func testARepeatStandsWhileNothingHoldsTheName() {
        XCTAssertTrue(APRSObjectKillRepeat.stillWanted(key: "ROADCLOSE", liveObjects: []))
    }

    /// Stand down, then place the same name again. The queued repeat must not
    /// go out — it would kill what we just placed.
    func testARepeatIsAbandonedOnceWePlaceTheNameAgain() throws {
        let ours = try live("ROADCLOSE", from: "K0EPI-7")
        XCTAssertFalse(APRSObjectKillRepeat.stillWanted(key: "ROADCLOSE", liveObjects: [ours]))
    }

    /// The worse case: someone else takes the name in the gap. APRS keys
    /// objects by name alone, so our repeat would remove theirs from every
    /// receiver on the channel, and nothing here would ever tell us.
    func testARepeatIsAbandonedWhenAnotherStationTakesTheName() throws {
        let theirs = try live("ROADCLOSE", from: "W0ARP-10")
        XCTAssertFalse(APRSObjectKillRepeat.stillWanted(key: "ROADCLOSE", liveObjects: [theirs]))
    }

    /// Another object being live does not abandon this one.
    func testAnUnrelatedObjectDoesNotAbandonTheRepeat() throws {
        let other = try live("AIDSTATION", from: "W0ARP-10")
        XCTAssertTrue(APRSObjectKillRepeat.stillWanted(key: "ROADCLOSE", liveObjects: [other]))
    }

    /// The key matches how the rest of the channel reads a name, or a repeat
    /// queued as "Fire" would sail past a live "FIRE␣␣".
    func testTheKeyIsCaseAndPaddingInsensitive() throws {
        let theirs = try live("FIRE", from: "W0ARP-10")
        XCTAssertEqual(APRSObjectKillRepeat.key("Fire  "), theirs.report.key)
        XCTAssertFalse(APRSObjectKillRepeat.stillWanted(
            key: APRSObjectKillRepeat.key("Fire  "), liveObjects: [theirs]))
    }
}
