import XCTest
@testable import AXTerm

/// Time labels under a session chart.
///
/// A packet session can be forty seconds or forty minutes, and the same
/// label style cannot serve both: `4:34:41 AM` under a one-minute chart is
/// six characters of noise repeated four times, and it is what pushed the
/// last tick off the right-hand edge.
final class ChartTimeAxisTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testShortSessionsLabelInSecondsNotWallClock() {
        let axis = ChartTimeAxis(span: 45)
        XCTAssertEqual(axis.style, .elapsedSeconds)
        XCTAssertEqual(axis.label(for: t0.addingTimeInterval(12), start: t0), "12s")
    }

    func testMinuteScaleSessionsLabelAsMinutesAndSeconds() {
        let axis = ChartTimeAxis(span: 8 * 60)
        XCTAssertEqual(axis.style, .elapsedMinutes)
        XCTAssertEqual(axis.label(for: t0.addingTimeInterval(3 * 60 + 5), start: t0), "3:05")
    }

    /// Past about an hour, elapsed stops being the useful frame — an
    /// operator correlating against a log wants the clock.
    func testLongSessionsFallBackToWallClock() {
        let axis = ChartTimeAxis(span: 3 * 3600)
        XCTAssertEqual(axis.style, .wallClock)
        XCTAssertFalse(axis.label(for: t0.addingTimeInterval(60), start: t0).isEmpty)
    }

    /// The clipped label in the report: every tick has to fit, so labels
    /// stay short whatever the span.
    func testEveryLabelIsShortEnoughToFit() {
        let spans: [TimeInterval] = [5, 45, 90, 8 * 60, 45 * 60, 3 * 3600, 26 * 3600]
        for span in spans {
            let axis = ChartTimeAxis(span: span)
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let label = axis.label(for: t0.addingTimeInterval(span * fraction), start: t0)
                XCTAssertLessThanOrEqual(label.count, 8, "\(label) at span \(span)")
                XCTAssertFalse(label.isEmpty)
            }
        }
    }

    /// Four ticks fit a panel this size; more is what crowded them into
    /// each other and off the edge.
    func testTickCountStaysSmallEnoughToFit() {
        XCTAssertEqual(ChartTimeAxis(span: 600).desiredTickCount, 4)
        // A degenerate span must not ask for zero or negative ticks.
        XCTAssertGreaterThanOrEqual(ChartTimeAxis(span: 0).desiredTickCount, 2)
    }

    /// A session with one sample has no span. The axis still has to render
    /// rather than divide by zero.
    func testAZeroSpanIsHandled() {
        let axis = ChartTimeAxis(span: 0)
        XCTAssertEqual(axis.label(for: t0, start: t0), "0s")
    }

    /// Clocks are not monotonic and a sample can precede the start after a
    /// time adjustment; a negative elapsed must not render as "-1:-5".
    func testASampleBeforeTheStartClampsToZero() {
        let axis = ChartTimeAxis(span: 300)
        XCTAssertEqual(axis.label(for: t0.addingTimeInterval(-30), start: t0), "0:00")
    }
}
