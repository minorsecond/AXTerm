import XCTest
import Combine
@testable import AXTerm

/// Telling a sleep apart from a fault.
///
/// The night of 2026-09-18 is the whole reason this type exists. The app could
/// not tell the difference, so it reported both the same way: a red line
/// reading `Connection failed: Socket is not connected (NWError 57)` and an
/// error-level Sentry event, for what turned out to be a display timing out.
final class PowerInterruptionTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func cause(drop: TimeInterval, slept: TimeInterval?, woke: TimeInterval?) -> LinkDropCause {
        PowerInterruption.cause(dropAt: t0.addingTimeInterval(drop),
                                sleptAt: slept.map { t0.addingTimeInterval($0) },
                                wokeAt: woke.map { t0.addingTimeInterval($0) })
    }

    // MARK: - The ordinary case

    /// A machine that has not slept since launch. Every drop is a fault, which
    /// is what we want: this is the common case and the one worth reporting.
    func testWithoutASleepEveryDropIsAFault() {
        XCTAssertEqual(cause(drop: 100, slept: nil, woke: nil), .fault)
    }

    /// A drop *before* the machine went to sleep is still a fault. The sleep
    /// cannot retroactively excuse a link that had already died.
    func testADropBeforeTheSleepIsStillAFault() {
        XCTAssertEqual(cause(drop: 50, slept: 100, woke: nil), .fault)
    }

    // MARK: - Asleep

    /// Between the warning and the wake, nothing is a fault.
    func testWhileAsleepNothingIsAFault() {
        XCTAssertEqual(cause(drop: 120, slept: 100, woke: nil), .systemSleep)
    }

    /// A stale wake from a *previous* sleep does not make the current one
    /// look finished.
    func testAnEarlierWakeDoesNotEndTheCurrentSleep() {
        XCTAssertEqual(cause(drop: 300, slept: 200, woke: 100), .systemSleep)
    }

    // MARK: - Just woken

    /// Sockets do not fail while the process is frozen, they fail in the first
    /// moments after it thaws — Network.framework catching up and discovering
    /// the connection it was holding is long gone. That catch-up belongs to
    /// the sleep.
    func testTheCatchUpAfterAWakeBelongsToTheSleep() {
        XCTAssertEqual(cause(drop: 205, slept: 100, woke: 200), .systemSleep)
        XCTAssertEqual(cause(drop: 200 + PowerInterruption.graceAfterWake,
                             slept: 100, woke: 200), .systemSleep)
    }

    /// Past the catch-up, the machine has been awake for a while and a link
    /// that drops now has nothing to do with the lid.
    func testADropLongAfterTheWakeIsAFaultAgain() {
        XCTAssertEqual(cause(drop: 200 + PowerInterruption.graceAfterWake + 1,
                             slept: 100, woke: 200), .fault)
    }

    /// The window is generous enough for a wake and short enough to be nowhere
    /// near the intervals at which a healthy link fails on its own.
    func testTheGraceWindowIsMinutesNotHours() {
        XCTAssertGreaterThanOrEqual(PowerInterruption.graceAfterWake, 30)
        XCTAssertLessThanOrEqual(PowerInterruption.graceAfterWake, 300)
    }

    // MARK: - Saying it

    /// "5880s" is not something anyone wants to divide at breakfast.
    func testDurationReadsAsWords() {
        XCTAssertEqual(PowerInterruption.duration(45), "45s")
        XCTAssertEqual(PowerInterruption.duration(600), "10m")
        XCTAssertEqual(PowerInterruption.duration(3600), "1h")
        XCTAssertEqual(PowerInterruption.duration(5880), "1h 38m")
    }

    /// The gap is stated as a fact, with a cause, rather than left to be
    /// inferred from a hole in the timestamps.
    func testTheOutageLineNamesTheGapAndTheReason() {
        let from = t0
        let to = t0.addingTimeInterval(5880)
        let line = PowerInterruption.outageSummary(from: from, to: to)
        XCTAssertTrue(line.contains("1h 38m"), line)
        XCTAssertTrue(line.lowercased().contains("asleep"), line)
        XCTAssertTrue(line.lowercased().contains("off the air"), line)
    }
}

/// The monitor's own bookkeeping, driven by hand rather than by a real sleep.
@MainActor
final class SystemPowerMonitorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A fresh monitor on a machine that has not slept.
    func testAFreshMonitorIsAwakeAndBlamesNothingOnSleep() {
        let monitor = SystemPowerMonitor()
        XCTAssertFalse(monitor.isAsleep)
        XCTAssertEqual(monitor.cause(forDropAt: t0), .fault)
    }

    func testItKnowsItIsAsleepBetweenTheWarningAndTheWake() {
        let monitor = SystemPowerMonitor()
        monitor.noteWillSleep(at: t0)
        XCTAssertTrue(monitor.isAsleep)
        XCTAssertEqual(monitor.cause(forDropAt: t0.addingTimeInterval(10)), .systemSleep)

        monitor.noteDidWake(at: t0.addingTimeInterval(5880))
        XCTAssertFalse(monitor.isAsleep)
    }

    /// The wake carries how long the machine was gone, which is what the
    /// console line is built from.
    func testWakingReportsHowLongItWasGone() {
        let monitor = SystemPowerMonitor()
        var reported: TimeInterval?
        let token = monitor.didWake.sink { reported = $0.outage }
        defer { token.cancel() }

        monitor.noteWillSleep(at: t0)
        monitor.noteDidWake(at: t0.addingTimeInterval(5880))

        XCTAssertEqual(reported ?? 0, 5880, accuracy: 0.001)
    }

    /// A wake with no sleep behind it — the app launched while the machine was
    /// coming up — reports no outage rather than inventing one.
    func testAWakeWithNoSleepBehindItReportsNoOutage() {
        let monitor = SystemPowerMonitor()
        var received = false
        var reported: TimeInterval?
        let token = monitor.didWake.sink { received = true; reported = $0.outage }
        defer { token.cancel() }

        monitor.noteDidWake(at: t0)

        XCTAssertTrue(received)
        XCTAssertNil(reported)
    }
}
