import XCTest
@testable import AXTerm

/// The map must ignore layout noise and honour real resizes.
///
/// MapKit re-anchors every annotation view whenever it presents a frame, so
/// a map whose size wobbles below a point shuffles all of its markers with
/// nothing in the app's data to explain it. Reproduced in isolation before
/// this existed: a width alternating by 0.5pt at 2 Hz moved fifty markers
/// 1910 times in ten seconds.
final class MapFrameStabilityTests: XCTestCase {

    func testSubPointWobbleIsNotAResize() {
        XCTAssertFalse(MapFrameStability.isRealResize(
            width: 1200.5, height: 800, currentWidth: 1200, currentHeight: 800))
        XCTAssertFalse(MapFrameStability.isRealResize(
            width: 1200, height: 800.4, currentWidth: 1200, currentHeight: 800))
        XCTAssertFalse(MapFrameStability.isRealMove(
            x: 0.5, y: 0, currentX: 0, currentY: 0))
    }

    func testAGenuineResizeStillCountsAsOne() {
        XCTAssertTrue(MapFrameStability.isRealResize(
            width: 1201, height: 800, currentWidth: 1200, currentHeight: 800))
        XCTAssertTrue(MapFrameStability.isRealResize(
            width: 900, height: 800, currentWidth: 1200, currentHeight: 800),
            "dragging the sidebar must not be swallowed")
        XCTAssertTrue(MapFrameStability.isRealMove(
            x: 0, y: 0, currentX: 0, currentY: 40))
    }

    /// Rounding was tried and measured worse: 1200.0 and 1200.5 round to
    /// 1200 and 1201, which is the same oscillation one point wider. Always
    /// settling downward means a size drifting inside one point resolves to
    /// a single value.
    func testSettlingAlwaysGoesDownSoOneValueWins() {
        XCTAssertEqual(MapFrameStability.settled(1200.0), 1200)
        XCTAssertEqual(MapFrameStability.settled(1200.5), 1200)
        XCTAssertEqual(MapFrameStability.settled(1200.99), 1200)
        XCTAssertEqual(MapFrameStability.settled(1201.0), 1201)
    }

    /// The loop that mattered: a value alternating by half a point must
    /// reach a fixed point rather than flipping forever.
    func testAnOscillatingWidthConvergesToOneValue() {
        var applied: CGFloat = 1200
        for step in 0..<20 {
            let proposed: CGFloat = step.isMultiple(of: 2) ? 1200.0 : 1200.5
            if MapFrameStability.isRealChange(proposed, current: applied) {
                applied = MapFrameStability.settled(proposed)
            }
        }
        XCTAssertEqual(applied, 1200, "the map settled on one width and stayed there")
    }
}
