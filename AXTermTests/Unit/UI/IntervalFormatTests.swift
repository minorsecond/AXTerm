import XCTest
@testable import AXTerm

/// The picker's job is to never misstate what is set. A menu row reading
/// "1 hour" for a value of 61 minutes, or a custom editor opening 90
/// minutes as "1 hour" and quietly rounding the rest away, would each be
/// the control lying about the setting behind it.
final class IntervalFormatTests: XCTestCase {

    // MARK: - Words

    func testIntervalsReadTheWayTheyAreSpoken() {
        XCTAssertEqual(IntervalFormat.label(seconds: 30), "30 s")
        XCTAssertEqual(IntervalFormat.label(seconds: 90), "1 min 30 s")
        XCTAssertEqual(IntervalFormat.label(seconds: 300), "5 min")
        XCTAssertEqual(IntervalFormat.label(seconds: 3600), "1 hour")
        XCTAssertEqual(IntervalFormat.label(seconds: 7200), "2 hours")
        XCTAssertEqual(IntervalFormat.label(seconds: 5400), "1 hr 30 min")
        XCTAssertEqual(IntervalFormat.label(seconds: 86_400), "1 day")
        XCTAssertEqual(IntervalFormat.label(seconds: 172_800), "2 days")
    }

    /// A third component is always the one carrying no meaning: nobody
    /// sets a probe floor of one hour, one minute and twenty seconds.
    func testAtMostTwoComponents() {
        XCTAssertEqual(IntervalFormat.label(seconds: 3680), "1 hr 1 min")
        XCTAssertEqual(IntervalFormat.label(seconds: 90_061), "1 d 1 hr")
    }

    func testZeroIsSpelledOutRatherThanShownAsANumber() {
        XCTAssertEqual(IntervalFormat.label(seconds: 0), "Off")
        XCTAssertEqual(IntervalFormat.label(seconds: 0, off: "No limit"), "No limit")
    }

    // MARK: - The unit the editor opens in

    /// 90 minutes is not "an hour and a half" to a control that holds one
    /// number: opening it in hours would show 1 and lose the rest.
    func testTheEditorOpensInTheLargestUnitThatDividesExactly() {
        XCTAssertEqual(IntervalFormat.naturalUnit(seconds: 5400), .minutes)
        XCTAssertEqual(IntervalFormat.naturalUnit(seconds: 3600), .hours)
        XCTAssertEqual(IntervalFormat.naturalUnit(seconds: 172_800), .days)
        XCTAssertEqual(IntervalFormat.naturalUnit(seconds: 90), .seconds)
    }

    /// A setting stored in whole minutes must not offer seconds — the
    /// store would round the number away the moment it was typed.
    func testAMinutesSettingIsNeverEditedInSeconds() {
        XCTAssertEqual(IntervalFormat.naturalUnit(seconds: 90, notBelow: .minutes), .minutes)
        XCTAssertEqual(IntervalFormat.units(notBelow: .minutes),
                       [.minutes, .hours, .days])
        XCTAssertEqual(IntervalFormat.units(notBelow: .seconds),
                       [.seconds, .minutes, .hours, .days])
    }

    // MARK: - Writing a custom value back

    /// Rounded up, not down. These settings are floors: rounding down
    /// would transmit sooner than the operator asked for.
    func testACustomValueRoundsUpToWhatTheStoreCanHold() {
        XCTAssertEqual(
            IntervalFormat.clamp(amount: 90, unit: .seconds, floor: .minutes), 120,
            "90 s in a minutes-backed setting is 2 minutes, not 1")
        XCTAssertEqual(
            IntervalFormat.clamp(amount: 90, unit: .seconds, floor: .seconds), 90)
        XCTAssertEqual(
            IntervalFormat.clamp(amount: 2, unit: .hours, floor: .minutes), 7200)
    }

    func testACustomValueCannotBeZeroOrAbsurd() {
        XCTAssertEqual(
            IntervalFormat.clamp(amount: 0, unit: .minutes, floor: .minutes), 60,
            "Off is an explicit menu entry, not something typed into the editor")
        XCTAssertEqual(
            IntervalFormat.clamp(amount: 9999, unit: .days, floor: .minutes),
            IntervalFormat.maximumSeconds)
    }

    // MARK: - The menu

    /// A macOS pop-up whose selection matches no tag renders blank, so a
    /// value from the custom editor has to appear in the list.
    func testACustomValueIsSplicedIntoTheMenuInOrder() {
        XCTAssertEqual(
            IntervalFormat.options(presets: [60, 300, 900], current: 420),
            [60, 300, 420, 900])
        XCTAssertEqual(
            IntervalFormat.options(presets: [60, 300, 900], current: 300),
            [60, 300, 900],
            "a preset is already there")
    }

    /// Off has its own menu entry; splicing a second zero in would show it
    /// twice.
    func testOffIsNotSplicedIntoThePresets() {
        XCTAssertEqual(IntervalFormat.options(presets: [60, 300], current: 0), [60, 300])
    }
}
