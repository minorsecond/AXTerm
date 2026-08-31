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

    /// DIGI is excluded from the classes that partition the console.
    func testDigipeatsIsNotAMessageClass() {
        XCTAssertFalse(Kind.messageClasses.contains(.digipeats))
        XCTAssertEqual(Kind.messageClasses.count, Kind.allCases.count - 1)
    }
}
