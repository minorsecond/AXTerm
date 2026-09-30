import XCTest
@testable import AXTerm

/// Deciding what to put back on the radio, and what to leave.
final class RigPrepRestoreTests: XCTestCase {

    private typealias Entry = RigPrepSnapshot.Entry

    private let mode = Entry(setting: .mode, original: [0x01, 0x02, 0x00, 0x00], applied: [0x05, 0x01, 0x01, 0x01])
    private let dataMod = Entry(setting: .menuItem(119), original: [0x00], applied: [0x01])
    private let notch = Entry(setting: .autoNotch, original: [0x01], applied: [0x00])
    private let squelch = Entry(setting: .squelch, original: [0x00, 0x50], applied: [0x00, 0x00])

    private var snapshot: RigPrepSnapshot { RigPrepSnapshot(entries: [mode, dataMod, notch, squelch]) }

    /// Every setting still as AXTerm left it.
    private var allApplied: [RigPrepSetting: [UInt8]] {
        Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.setting, $0.applied) })
    }

    // MARK: - Planning

    func testAnEmptySnapshotPlansNothing() {
        let plan = RigPrepRestore.plan(RigPrepSnapshot(), current: [:])
        XCTAssertEqual(plan, RigPrepRestore.Plan())
        XCTAssertNil(RigPrepRestore.notice(RigPrepRestore.Outcome()))
    }

    func testEverythingStillAppliedIsRestoredInReverseOrder() {
        let plan = RigPrepRestore.plan(snapshot, current: allApplied)
        XCTAssertEqual(plan.writes.map(\.setting), [.squelch, .autoNotch, .menuItem(119), .mode],
                       "last applied, first restored")
        XCTAssertEqual(plan.writes.map(\.original), [[0x00, 0x50], [0x01], [0x00], [0x01, 0x02, 0x00, 0x00]])
        XCTAssertTrue(plan.changedByOperator.isEmpty)
        XCTAssertTrue(plan.alreadyBack.isEmpty)
    }

    /// The operator opened the squelch a little mid-session. It is theirs now.
    func testASettingTheOperatorChangedIsLeftAlone() {
        var current = allApplied
        current[.squelch] = [0x00, 0x20]
        let plan = RigPrepRestore.plan(snapshot, current: current)
        XCTAssertEqual(plan.changedByOperator.map(\.setting), [.squelch])
        XCTAssertFalse(plan.writes.contains { $0.setting == .squelch })
        XCTAssertEqual(plan.writes.map(\.setting), [.autoNotch, .menuItem(119), .mode])
    }

    func testASettingAlreadyBackIsNotWritten() {
        var current = allApplied
        current[.autoNotch] = [0x01]   // the operator turned the notch back on themselves
        let plan = RigPrepRestore.plan(snapshot, current: current)
        XCTAssertEqual(plan.alreadyBack.map(\.setting), [.autoNotch])
        XCTAssertFalse(plan.writes.contains { $0.setting == .autoNotch })
    }

    /// An unanswered read is no evidence the operator changed anything.
    func testAnUnreadSettingIsRestored() {
        var current = allApplied
        current[.menuItem(119)] = nil
        let plan = RigPrepRestore.plan(snapshot, current: current)
        XCTAssertTrue(plan.writes.contains { $0.setting == .menuItem(119) })
    }

    func testNothingReadAtAllRestoresEverything() {
        XCTAssertEqual(RigPrepRestore.plan(snapshot, current: [:]).writes.map(\.setting),
                       [.squelch, .autoNotch, .menuItem(119), .mode])
    }

    /// The mode is one setting: the operator switching FM-D to FM (data off)
    /// is a change to it, and it is left alone as a whole.
    func testAPartialModeChangeCountsAsTheOperators() {
        var current = allApplied
        current[.mode] = [0x05, 0x01, 0x00, 0x00]
        let plan = RigPrepRestore.plan(snapshot, current: current)
        XCTAssertEqual(plan.changedByOperator.map(\.setting), [.mode])
    }

    // MARK: - What is still owed

    func testAPartialFailureKeepsOnlyTheFailures() {
        var outcome = RigPrepRestore.Outcome()
        outcome.restored = [squelch, mode]
        outcome.failed = [notch]
        outcome.changedByOperator = [dataMod]
        let left = RigPrepRestore.remaining(snapshot, after: outcome)
        XCTAssertEqual(left.settings, [.autoNotch])
        XCTAssertEqual(left.entry(for: .autoNotch)?.original, [0x01], "the original is kept for the retry")
    }

    func testWhatWasNeverReachedStaysOwed() {
        var outcome = RigPrepRestore.Outcome()
        outcome.restored = [squelch]
        outcome.notAttempted = [notch, dataMod, mode]
        XCTAssertEqual(RigPrepRestore.remaining(snapshot, after: outcome).settings, [.mode, .menuItem(119), .autoNotch],
                       "kept in the order they were applied, so the next restore reverses them again")
    }

    func testAFullRestoreOwesNothing() {
        var outcome = RigPrepRestore.Outcome()
        outcome.restored = [squelch, notch, dataMod]
        outcome.alreadyBack = [mode]
        XCTAssertTrue(RigPrepRestore.remaining(snapshot, after: outcome).isEmpty)
    }

    /// A retry after a partial failure plans only what is left, still in
    /// reverse.
    func testARetryAfterAPartialFailure() {
        var outcome = RigPrepRestore.Outcome()
        outcome.restored = [squelch, dataMod]
        outcome.failed = [notch, mode]
        let left = RigPrepRestore.remaining(snapshot, after: outcome)
        let plan = RigPrepRestore.plan(left, current: [.autoNotch: [0x00], .mode: [0x05, 0x01, 0x01, 0x01]])
        XCTAssertEqual(plan.writes.map(\.setting), [.autoNotch, .mode])
    }

    // MARK: - The notice

    func testTheNoticeSaysWhatWasPutBack() throws {
        var outcome = RigPrepRestore.Outcome()
        outcome.restored = [squelch, notch, mode]
        let notice = try XCTUnwrap(RigPrepRestore.notice(outcome))
        XCTAssertEqual(notice, "Put the radio back as it was: squelch, auto notch, mode.")
    }

    func testTheNoticeNamesWhatWasLeftAndWhatFailed() throws {
        var outcome = RigPrepRestore.Outcome()
        outcome.restored = [notch]
        outcome.changedByOperator = [squelch]
        outcome.failed = [mode]
        outcome.notAttempted = [dataMod]
        let notice = try XCTUnwrap(RigPrepRestore.notice(outcome))
        XCTAssertTrue(notice.contains("Put the radio back as it was: auto notch."), notice)
        XCTAssertTrue(notice.contains("Left squelch as you set it during the session."), notice)
        XCTAssertTrue(notice.contains("Could not put back mode, DATA MOD"), notice)
        XCTAssertTrue(notice.contains("try again"), notice)
        XCTAssertFalse(notice.contains("\u{2014}"), "no em dashes in UI text")
    }

    func testANoticeWithOnlyAlreadyBackSaysNothing() {
        var outcome = RigPrepRestore.Outcome()
        outcome.alreadyBack = [notch]
        XCTAssertNil(RigPrepRestore.notice(outcome))
    }

    func testFourTXDelaysReadAsFourSettings() throws {
        var outcome = RigPrepRestore.Outcome()
        outcome.restored = [38, 39, 41, 42].map { Entry(setting: .menuItem($0), original: [0x01], applied: [0x00]) }
        let notice = try XCTUnwrap(RigPrepRestore.notice(outcome))
        XCTAssertTrue(notice.contains("TX delay (HF), TX delay (50 MHz), TX delay (144 MHz), TX delay (430 MHz)"), notice)
    }

    // MARK: - Corrections as values

    func testCorrectionTargets() {
        XCTAssertEqual(RigPrep.target(for: .attenuatorOff, current: [0x20]), [0x00])
        XCTAssertEqual(RigPrep.target(for: .rfGainFull, current: [0x01, 0x28]), [0x02, 0x55])
        XCTAssertEqual(RigPrep.target(for: .squelchOpen, current: [0x00, 0x50]), [0x00, 0x00])
        XCTAssertEqual(RigPrep.target(for: .noiseReductionOff, current: [0x01]), [0x00])
        XCTAssertEqual(RigPrep.target(for: .noiseBlankerOff, current: [0x01]), [0x00])
        XCTAssertEqual(RigPrep.target(for: .autoNotchOff, current: [0x01]), [0x00])
        XCTAssertEqual(RigPrep.target(for: .manualNotchOff, current: [0x01]), [0x00])
        XCTAssertEqual(RigPrep.target(for: .widestFilter, current: [0x01, 0x03, 0x01, 0x03]), [0x01, 0x01, 0x01, 0x01],
                       "FIL1, and data mode kept on")
        XCTAssertEqual(RigPrep.target(for: .widestFilter, current: [0x05, 0x02, 0x00, 0x00]), [0x05, 0x01, 0x00, 0x00])
        XCTAssertNil(RigPrep.target(for: .autoNotchOff, current: [0x09]), "not a value this can judge")
        XCTAssertNil(RigPrep.target(for: .toneSquelchReceiveOff, current: [0x05]))
    }

    /// Only the receive decoder goes; whatever the radio transmits stays.
    func testToneSquelchKeepsTheTransmitTone() {
        let cases: [(UInt8, UInt8)] = [
            (0x00, 0x00), (0x01, 0x01), (0x06, 0x06),   // nothing muting receive
            (0x02, 0x01),                               // TSQL: tone both ways -> TONE
            (0x03, 0x06),                               // DTCS both ways -> DTCS(T)
            (0x07, 0x01),                               // TONE(T)/DTCS(R) -> TONE
            (0x08, 0x06),                               // DTCS(T)/TSQL(R) -> DTCS(T)
            (0x09, 0x01),                               // TONE(T)/TSQL(R) -> TONE
        ]
        for (from, to) in cases {
            XCTAssertEqual(RigPrep.target(for: .toneSquelchReceiveOff, current: [from]), [to],
                           String(format: "%02X", from))
        }
    }

    func testReceiveClearsLeaveThePreampAlone() {
        XCTAssertFalse(RigPrep.receiveClears(toneSquelchFunction: true).map(RigPrep.setting(for:)).contains(.mode))
        XCTAssertEqual(RigPrep.receiveClears(toneSquelchFunction: false).count, 7)
        XCTAssertEqual(RigPrep.receiveClears(toneSquelchFunction: true).last, .toneSquelchReceiveOff)
    }

    func testTheToneSquelchCommandIsOnlyAskedOfAnIC705() {
        XCTAssertTrue(RigPrep.confirmsToneSquelchFunction(model: nil, address: 0xA4))
        XCTAssertTrue(RigPrep.confirmsToneSquelchFunction(model: "IC-705", address: 0x42))
        XCTAssertFalse(RigPrep.confirmsToneSquelchFunction(model: "IC-7300", address: 0x94))
        XCTAssertFalse(RigPrep.confirmsToneSquelchFunction(model: nil, address: 0x98))
    }

    func testChangeDescriptions() {
        XCTAssertEqual(RigPrep.describe(.autoNotch, from: [0x01], to: [0x00]), "auto notch off")
        XCTAssertEqual(RigPrep.describe(.toneSquelch, from: [0x02], to: [0x01]), "tone squelch TSQL to TONE")
        XCTAssertEqual(RigPrep.describe(.rfGain, from: [0x01, 0x28], to: [0x02, 0x55]), "RF gain full")
    }
}
