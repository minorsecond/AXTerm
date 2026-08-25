import XCTest
@testable import AXTerm

/// How a routing entry reads on a handheld.
///
/// The macOS tables put nine columns side by side; on an 834pt iPad that
/// truncated the destination callsign — the one field a routing view exists
/// to show — while `Hops` kept a column to itself. Stacking the same facts
/// means composing them, and what a routing table claims about a link is the
/// product rather than decoration, so the composition is pinned here.
final class NetRomTouchRowTests: XCTestCase {

    private typealias Row = NetRomTouchRow

    // MARK: - Headline

    /// Destination and next hop are one fact, not two columns to reassemble.
    func testHeadlinePairsDestinationWithNextHop() {
        XCTAssertEqual(Row.headline(destination: "EVANS", nextHop: "DRLNOD"),
                       "EVANS → DRLNOD")
    }

    /// A direct route has no hop to name, and "DRLNOD → DRLNOD" would invent
    /// one.
    func testHeadlineOmitsARedundantNextHop() {
        XCTAssertEqual(Row.headline(destination: "DRLNOD", nextHop: "DRLNOD"), "DRLNOD")
        XCTAssertEqual(Row.headline(destination: "DRLNOD", nextHop: ""), "DRLNOD")
    }

    // MARK: - Hop counts

    func testAKnownHopCountIsSingularOrPluralCorrectly() {
        XCTAssertTrue(Row.detail(hops: 1, updated: "", freshness: "").contains("1 hop"))
        XCTAssertFalse(Row.detail(hops: 1, updated: "", freshness: "").contains("1 hops"))
        XCTAssertTrue(Row.detail(hops: 3, updated: "", freshness: "").contains("3 hops"))
    }

    /// An unknown hop count is omitted rather than dashed. The table could
    /// print "—" under a `Hops` header and be understood; on a row with no
    /// column labels a bare dash reads as a value, and "— hops" reads as
    /// nothing at all.
    func testAnUnknownHopCountIsOmittedNotDashed() {
        let detail = Row.detail(hops: nil, updated: "7m ago", freshness: "95%")
        XCTAssertEqual(detail, "7m ago · 95%")
        XCTAssertFalse(detail.contains("—"))
        XCTAssertFalse(detail.contains("hop"))
    }

    /// Unknown is not zero. A route heard by broadcast carries no hop count,
    /// and "0 hops" would claim the destination is this station.
    func testZeroHopsIsDistinctFromUnknown() {
        XCTAssertTrue(Row.detail(hops: 0, updated: "", freshness: "").contains("0 hops"))
        XCTAssertNotEqual(Row.detail(hops: 0, updated: "x", freshness: ""),
                          Row.detail(hops: nil, updated: "x", freshness: ""))
    }

    /// Absent fields leave no orphaned separators.
    func testAbsentFieldsLeaveNoDanglingSeparators() {
        XCTAssertEqual(Row.detail(hops: nil, updated: "", freshness: ""), "")
        XCTAssertEqual(Row.detail(hops: nil, updated: "", freshness: "95%"), "95%")
        XCTAssertFalse(Row.detail(hops: 2, updated: "", freshness: "").hasSuffix("·"))
    }

    // MARK: - Path

    /// A single-hop route's path *is* its next hop; repeating it under the
    /// headline spends a line to say one word twice.
    func testAPathIsHiddenWhenItOnlyRepeatsTheNextHop() {
        XCTAssertFalse(Row.shouldShowPath("DRLNOD", nextHop: "DRLNOD"))
        XCTAssertFalse(Row.shouldShowPath("", nextHop: "DRLNOD"))
        XCTAssertTrue(Row.shouldShowPath("DRLNOD,FNKTWN", nextHop: "DRLNOD"))
    }

    // MARK: - Metrics

    /// A dash means *no observation yet*, which is the opposite claim to a
    /// measured zero. Printing 0.00 for an unmeasured link would assert a
    /// dead path where the truth is silence.
    func testAnUnmeasuredMetricIsDashedNotZeroed() {
        XCTAssertEqual(Row.metric(nil, decimals: 2), "—")
        XCTAssertEqual(Row.metric(0, decimals: 2), "0.00")
    }

    func testMetricsKeepTheirRequestedPrecision() {
        XCTAssertEqual(Row.metric(0.9666, decimals: 2), "0.97")
        XCTAssertEqual(Row.metric(3.76, decimals: 1), "3.8")
    }

    // MARK: - Spoken

    /// "df 0.97 dr 0.96" is meaningless read aloud, so VoiceOver gets the
    /// directions named and the probabilities as percentages.
    func testSpokenLinkNamesBothDirections() {
        let spoken = Row.spokenLink(from: "K0EPI-7", to: "KB5YZB-7", df: 0.97, dr: 0.96)
        XCTAssertTrue(spoken.contains("K0EPI-7"), spoken)
        XCTAssertTrue(spoken.contains("KB5YZB-7"), spoken)
        XCTAssertTrue(spoken.contains("forward"), spoken)
        XCTAssertTrue(spoken.contains("reverse"), spoken)
        XCTAssertTrue(spoken.contains("97"), spoken)
    }

    /// An unmeasured direction is left unsaid rather than spoken as zero.
    func testSpokenLinkOmitsUnmeasuredDirections() {
        let spoken = Row.spokenLink(from: "A", to: "B", df: nil, dr: nil)
        XCTAssertFalse(spoken.contains("forward"), spoken)
        XCTAssertFalse(spoken.contains("reverse"), spoken)
        XCTAssertTrue(spoken.contains("A"), spoken)
    }
}
