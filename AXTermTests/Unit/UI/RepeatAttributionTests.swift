import XCTest
@testable import AXTerm

/// Telling a direct copy from a digipeated one.
///
/// Reported as a duplicate ID from KB5YZB-7 — two identical lines, same
/// second. They were not duplicates. The station's beacon was heard twice:
/// once direct, and 0.85 s later as DRLNOD's retransmission. Over this
/// station's history that pairing is routine — 122 copies with a clean via
/// path against 402 carrying DRLNOD's H bit.
///
/// The console had the fact and did not show it: the repeat marker was
/// reserved for echoes of *our own* frames, so for anyone else's traffic the
/// two copies rendered as the same words. Which one you are looking at is
/// the whole difference between "I hear KB5YZB-7" and "DRLNOD hears
/// KB5YZB-7".
final class RepeatAttributionTests: XCTestCase {

    private func line(via: [String], from: String = "KB5YZB-7") -> ConsoleLine {
        ConsoleLine(
            timestamp: Date(timeIntervalSince1970: 1_788_000_000),
            from: from,
            to: "ID",
            text: "KB5YZB/R YZBBPQ/D KB5YZB-1/B KB5YZB-7/N",
            via: via)
    }

    /// The copy that reached us before any digi touched it.
    func testACleanViaPathIsHeardDirect() {
        XCTAssertNil(line(via: ["DRLNOD", "FNKTWN"])
            .repeatAttribution(localCallsign: "K0EPI-7"))
    }

    /// The copy DRLNOD retransmitted. This is the one the operator could not
    /// tell apart.
    func testAnHBitMeansWeHeardTheDigipeater() {
        let attribution = line(via: ["DRLNOD*", "FNKTWN"])
            .repeatAttribution(localCallsign: "K0EPI-7")
        XCTAssertEqual(attribution, .heardVia(["DRLNOD"]))
    }

    /// Our own frame coming back off a digi is a different fact — it carries
    /// no new content, and the transmit line already showed it. Kept
    /// distinct so it can go on being dimmed.
    func testOurOwnFrameComingBackIsAnEcho() {
        let attribution = line(via: ["DRLNOD*"], from: "K0EPI-7")
            .repeatAttribution(localCallsign: "K0EPI-7")
        XCTAssertEqual(attribution, .ourFrameEchoed(["DRLNOD"]))
    }

    /// Only the digis that actually repeated it are named. An unused hop
    /// further down the path did not transmit this copy.
    func testOnlyTheDigisThatRepeatedAreNamed() {
        let attribution = line(via: ["DRLNOD*", "FNKTWN"])
            .repeatAttribution(localCallsign: "K0EPI-7")
        XCTAssertEqual(attribution?.digis, ["DRLNOD"])
    }

    func testMultipleRepeatersAreAllNamed() {
        let attribution = line(via: ["DRLNOD*", "FNKTWN*"])
            .repeatAttribution(localCallsign: "K0EPI-7")
        XCTAssertEqual(attribution?.digis, ["DRLNOD", "FNKTWN"])
    }

    /// A frame with no path at all is direct by definition.
    func testNoPathIsDirect() {
        XCTAssertNil(line(via: []).repeatAttribution(localCallsign: "K0EPI-7"))
    }
}
