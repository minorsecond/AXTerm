import XCTest
@testable import AXTerm

/// Isolating one kind of console line.
///
/// Switching off the other seven chips was eight gestures to answer one
/// question ("what did the BBS actually say?"), so a solo has to be one.
final class ConsoleFilterSoloTests: XCTestCase {

    private typealias Kind = ConsoleTypeFilterFlags.Kind

    func testSoloShowsOneClassAndHidesTheRest() {
        var flags = ConsoleTypeFilterFlags()
        flags.solo(.data)

        XCTAssertTrue(flags.showData)
        for kind in Kind.messageClasses where kind != .data {
            XCTAssertFalse(flags[kind], "\(kind.label) should be off")
        }
        XCTAssertTrue(flags.isSoloed(.data))
        XCTAssertEqual(flags.restrictionSummary, "DATA only")
    }

    /// Whether the operator wants to see echoes of their own frames is a
    /// separate preference from which classes they are reading — an echoed
    /// DATA frame is still DATA.
    func testSoloingAClassLeavesTheEchoPreferenceAlone() {
        var on = ConsoleTypeFilterFlags()
        on.showDigipeats = true
        on.solo(.data)
        XCTAssertTrue(on.showDigipeats)

        var off = ConsoleTypeFilterFlags()
        off.solo(.data)
        XCTAssertFalse(off.showDigipeats)
    }

    /// DIGI is an overlay, not a ninth class: every echo is also an ID or a
    /// DATA line. Soloing it by switching the seven classes off would show an
    /// empty console — the opposite of what was asked for.
    func testSoloingDigipeatsKeepsTheClassesOnAndFiltersToEchoes() {
        var flags = ConsoleTypeFilterFlags()
        flags.solo(.digipeats)

        XCTAssertTrue(flags.digipeatsOnly)
        XCTAssertTrue(flags.showDigipeats)
        for kind in Kind.messageClasses {
            XCTAssertTrue(flags[kind], "\(kind.label) must stay on")
        }
        XCTAssertTrue(flags.isSoloed(.digipeats))
        XCTAssertEqual(flags.restrictionSummary, "digipeat echoes only")
    }

    /// Only one thing can be soloed at a time, or the badge lies.
    func testSoloingIsExclusive() {
        var flags = ConsoleTypeFilterFlags()
        flags.solo(.data)
        flags.solo(.beacon)

        XCTAssertTrue(flags.isSoloed(.beacon))
        XCTAssertFalse(flags.isSoloed(.data))
    }

    /// Every class showing is not "everything soloed".
    func testTheDefaultIsNotASolo() {
        let flags = ConsoleTypeFilterFlags()
        XCTAssertTrue(flags.isShowingEveryClass)
        XCTAssertNil(flags.restrictionSummary)
        for kind in Kind.allCases {
            XCTAssertFalse(flags.isSoloed(kind), "\(kind.label)")
        }
    }

    func testShowAllTypesUndoesASolo() {
        var flags = ConsoleTypeFilterFlags()
        flags.solo(.data)
        flags.showAllTypes()

        XCTAssertTrue(flags.isShowingEveryClass)
        XCTAssertNil(flags.restrictionSummary)
    }

    /// Echoes are off by default because they are noise. Restoring the
    /// classes must not quietly turn the operator's own echoes back on.
    func testShowAllTypesDoesNotTurnEchoesOn() {
        var flags = ConsoleTypeFilterFlags()
        flags.showAllTypes()
        XCTAssertFalse(flags.showDigipeats)
    }

    /// Coming out of "only DIGI" has to clear the echo-only axis too, or
    /// "Show All Types" leaves the console showing nothing but echoes.
    func testShowAllTypesClearsTheEchoOnlyFilter() {
        var flags = ConsoleTypeFilterFlags()
        flags.solo(.digipeats)
        flags.showAllTypes()

        XCTAssertFalse(flags.digipeatsOnly)
        XCTAssertTrue(flags.isShowingEveryClass)
    }

    /// Hand-toggled combinations still get named, so a console filtered by
    /// clicking rather than soloing says so too.
    func testAHandToggledSubsetNamesWhatIsHidden() {
        var flags = ConsoleTypeFilterFlags()
        flags.showSystem = false
        flags.showOther = false
        XCTAssertEqual(flags.restrictionSummary, "no OTHER/SYS")
        XCTAssertFalse(flags.isShowingEveryClass)
    }

    /// An empty console from a quiet channel and one from every chip being
    /// off look identical.
    func testEverythingOffIsCalledOut() {
        var flags = ConsoleTypeFilterFlags()
        for kind in Kind.messageClasses { flags[kind] = false }
        XCTAssertEqual(flags.restrictionSummary, "every type hidden")
    }

    /// The axes are excluded from the classes that partition the console.
    func testTheAxesAreNotMessageClasses() {
        XCTAssertFalse(Kind.messageClasses.contains(.digipeats))
        XCTAssertFalse(Kind.messageClasses.contains(.mine))
        XCTAssertEqual(Kind.messageClasses.count, 7)
        XCTAssertEqual(Kind.messageClasses.count, Kind.allCases.count - 2)
    }
}

/// Showing only what this station is a party to.
///
/// The single biggest lever on a busy channel: on this operator's own
/// capture, 71% of frames involve neither end of their station, and a
/// stranger's Winlink session fills the console for minutes at a time.
final class ConsoleMineFilterTests: XCTestCase {

    private func line(from: String?, to: String?, via: [String] = []) -> ConsoleLine {
        ConsoleLine(kind: .packet, from: from, to: to, text: "x", via: via)
    }

    func testTrafficWeSentOrReceivedCounts() {
        XCTAssertTrue(line(from: "K0EPI-7", to: "DRLNOD").involvesStation("K0EPI-7"))
        XCTAssertTrue(line(from: "DRLNOD", to: "K0EPI-7").involvesStation("K0EPI-7"))
    }

    /// A frame we digipeated went out of our transmitter, whoever it was
    /// addressed to.
    func testAFrameWeRepeatedCounts() {
        XCTAssertTrue(line(from: "KB5YZB-7", to: "K0NTS-1", via: ["K0EPI-7*"])
            .involvesStation("K0EPI-7"))
    }

    /// K0EPI-7 on the terminal and K0EPI-10 on Winlink are the same operator
    /// at the same desk. Showing one and hiding the other would be a worse
    /// answer to "what am I doing" than no filter at all.
    func testEverySSIDOfOurCallsignCounts() {
        XCTAssertTrue(line(from: "K0EPI-10", to: "WN6OTL").involvesStation("K0EPI-7"))
        XCTAssertTrue(line(from: "K0EPI", to: "WN6OTL").involvesStation("K0EPI-7"))
    }

    /// The case this filter exists for.
    func testSomeoneElsesSessionDoesNot() {
        XCTAssertFalse(line(from: "K0NTS-10", to: "WN6OTL").involvesStation("K0EPI-7"))
        XCTAssertFalse(line(from: "K0NTS-1", to: "N3HYM-15", via: ["DRLNOD*"])
            .involvesStation("K0EPI-7"))
    }

    /// With no callsign configured every line would look like someone else's,
    /// and the console would empty itself. Not filtering is the better answer.
    func testAnUnsetCallsignMatchesNothingRatherThanEverything() {
        XCTAssertFalse(line(from: "K0EPI-7", to: "DRLNOD").involvesStation(""))
    }

    func testTheFilterHidesOtherStationsAndKeepsOurs() {
        var flags = ConsoleTypeFilterFlags()
        flags.minesOnly = true
        let lines = [line(from: "K0EPI-7", to: "DRLNOD"),
                     line(from: "K0NTS-10", to: "WN6OTL")]

        let shown = ConsoleVisibilityFilter.apply(
            lines: lines, clearedAt: nil, flags: flags, localCallsign: "K0EPI-7")
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.from, "K0EPI-7")
    }

    /// Guard against the empty-console failure in the place it would happen.
    func testWithNoCallsignTheFilterIsInert() {
        var flags = ConsoleTypeFilterFlags()
        flags.minesOnly = true
        let lines = [line(from: "K0NTS-10", to: "WN6OTL")]

        XCTAssertEqual(
            ConsoleVisibilityFilter.apply(
                lines: lines, clearedAt: nil, flags: flags, localCallsign: "").count,
            1)
    }

    /// Our own traffic is still IDs and DATA, so soloing MINE must not switch
    /// the classes off the way soloing DATA does.
    func testSoloingMineKeepsEveryClassOn() {
        var flags = ConsoleTypeFilterFlags()
        flags.solo(.mine)

        XCTAssertTrue(flags.minesOnly)
        XCTAssertTrue(flags.isShowingEveryClass)
        XCTAssertTrue(flags.isSoloed(.mine))
        XCTAssertEqual(flags.restrictionSummary, "my traffic only")
    }

    /// The two axes are independent of the classes and of each other, and the
    /// status line has to name every restriction in force or it is worse than
    /// silent.
    func testAxesAndClassesAreReportedTogether() {
        var flags = ConsoleTypeFilterFlags()
        flags.minesOnly = true
        flags.showSystem = false
        XCTAssertEqual(flags.restrictionSummary, "my traffic only · no SYS")
    }

    func testShowAllTypesClearsTheMineFilter() {
        var flags = ConsoleTypeFilterFlags()
        flags.solo(.mine)
        flags.showAllTypes()

        XCTAssertFalse(flags.minesOnly)
        XCTAssertTrue(flags.isUnrestricted)
        XCTAssertNil(flags.restrictionSummary)
    }

    /// Neither axis is a class; treating them as one would make "show only
    /// mine" mean "show nothing".
    func testTheAxesAreNotMessageClasses() {
        XCTAssertFalse(ConsoleTypeFilterFlags.Kind.messageClasses.contains(.mine))
        XCTAssertTrue(ConsoleTypeFilterFlags.Kind.mine.isAxis)
        XCTAssertTrue(ConsoleTypeFilterFlags.Kind.digipeats.isAxis)
        XCTAssertFalse(ConsoleTypeFilterFlags.Kind.data.isAxis)
    }
}
