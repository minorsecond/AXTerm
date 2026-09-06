import XCTest
import MapKit
@testable import AXTerm

/// The map must not move what nobody moved.
///
/// The bug this suite exists for took most of a day to find, so it is worth
/// stating precisely. MapKit re-anchors every annotation view to pixel
/// boundaries whenever VectorKit presents a frame — the stack runs
/// `-[VKMapView didPresent]` → `-[MKMapView mapLayerDidDraw:]` →
/// `-[MKAnnotationContainerView _updateAnnotationViews:]` →
/// `-[MKAnnotationView _updateAnchorPosition:alignToPixels:]` → our
/// `setFrameOrigin`. Nothing of ours is above that. So a map whose *size*
/// wobbles by a fraction of a point re-projects, and every marker on it
/// shifts by up to a point, continuously, with the app's own data entirely
/// still.
///
/// Measured in an isolated harness: fifty annotation views at `.required`,
/// seventeen path lines, two coverage rings. Idle: 0 moves in 10s. Polling
/// the map's annotations and overlays at 2 Hz: 0. Forcing layout at 2 Hz: 0.
/// Oscillating the width by half a point at 2 Hz: **1910 moves in 10s**.
/// With the threshold below: 0, and a genuine resize still lays out.
///
/// Everything here is a pure function so it can be pinned without a map.
final class MapStabilityTests: XCTestCase {

    // MARK: - What counts as a change

    func testSubPointWobbleIsNotAResize() {
        XCTAssertFalse(MapFrameStability.isRealResize(
            width: 1200.5, height: 800, currentWidth: 1200, currentHeight: 800))
        XCTAssertFalse(MapFrameStability.isRealResize(
            width: 1200, height: 800.4, currentWidth: 1200, currentHeight: 800))
        XCTAssertFalse(MapFrameStability.isRealResize(
            width: 1199.25, height: 799.75, currentWidth: 1200, currentHeight: 800),
            "shrinking by a fraction is noise too")
    }

    func testSubPointDriftIsNotAMove() {
        XCTAssertFalse(MapFrameStability.isRealMove(
            x: 0.5, y: 0, currentX: 0, currentY: 0))
        XCTAssertFalse(MapFrameStability.isRealMove(
            x: 40, y: 39.6, currentX: 40, currentY: 40))
    }

    func testAGenuineResizeIsHonoured() {
        XCTAssertTrue(MapFrameStability.isRealResize(
            width: 1201, height: 800, currentWidth: 1200, currentHeight: 800),
            "exactly one point is a real change")
        XCTAssertTrue(MapFrameStability.isRealResize(
            width: 900, height: 800, currentWidth: 1200, currentHeight: 800),
            "dragging the sidebar must never be swallowed")
        XCTAssertTrue(MapFrameStability.isRealResize(
            width: 1200, height: 1400, currentWidth: 1200, currentHeight: 800),
            "entering full screen must never be swallowed")
    }

    func testAGenuineMoveIsHonoured() {
        XCTAssertTrue(MapFrameStability.isRealMove(
            x: 0, y: 0, currentX: 0, currentY: 40))
        XCTAssertTrue(MapFrameStability.isRealMove(
            x: 260, y: 0, currentX: 0, currentY: 0),
            "the sidebar opening shifts the map's origin")
    }

    /// The boundary itself, both sides, so the threshold cannot drift
    /// silently under someone editing it.
    func testTheThresholdIsExactlyOnePoint() {
        XCTAssertEqual(MapFrameStability.threshold, 1)
        XCTAssertTrue(MapFrameStability.isRealChange(101, current: 100))
        XCTAssertFalse(MapFrameStability.isRealChange(100.999, current: 100))
        XCTAssertTrue(MapFrameStability.isRealChange(99, current: 100))
        XCTAssertFalse(MapFrameStability.isRealChange(99.001, current: 100))
    }

    // MARK: - Settling

    /// Rounding was tried first and measured *worse*: 1200.0 and 1200.5
    /// round to 1200 and 1201, which is the same oscillation a point wider.
    func testSettlingAlwaysGoesDown() {
        XCTAssertEqual(MapFrameStability.settled(1200.0), 1200)
        XCTAssertEqual(MapFrameStability.settled(1200.5), 1200)
        XCTAssertEqual(MapFrameStability.settled(1200.99), 1200)
        XCTAssertEqual(MapFrameStability.settled(1201.0), 1201)
    }

    func testSettlingIsIdempotent() {
        for value in [0.0, 1.5, 799.75, 1200.5, 1201.0] as [CGFloat] {
            let once = MapFrameStability.settled(value)
            XCTAssertEqual(MapFrameStability.settled(once), once, "\(value)")
        }
    }

    // MARK: - The loop that actually bit

    /// Applying the rule repeatedly against an oscillating proposal must
    /// reach a fixed point. Any amplitude below a point, and any phase.
    func testAnOscillatingSizeConvergesAndStays() {
        for amplitude in [0.1, 0.25, 0.5, 0.75, 0.99] as [CGFloat] {
            var applied: CGFloat = 1200
            var changes = 0
            for step in 0..<50 {
                let proposed: CGFloat = 1200 + (step.isMultiple(of: 2) ? 0 : amplitude)
                if MapFrameStability.isRealChange(proposed, current: applied) {
                    applied = MapFrameStability.settled(proposed)
                    changes += 1
                }
            }
            XCTAssertEqual(changes, 0, "amplitude \(amplitude) kept re-projecting the map")
            XCTAssertEqual(applied, 1200, "amplitude \(amplitude)")
        }
    }

    /// Convergence must not come at the cost of tracking real resizes: a
    /// wobble, then a genuine drag, then a wobble around the new size.
    func testARealResizeStillLandsBetweenTwoWobbles() {
        var applied: CGFloat = 1200
        func propose(_ value: CGFloat) {
            if MapFrameStability.isRealChange(value, current: applied) {
                applied = MapFrameStability.settled(value)
            }
        }
        propose(1200.5); propose(1200.0); propose(1200.5)
        XCTAssertEqual(applied, 1200, "wobble absorbed")

        propose(940.5)
        XCTAssertEqual(applied, 940, "the drag landed")

        propose(940.0); propose(940.5); propose(940.25)
        XCTAssertEqual(applied, 940, "and settled again at the new size")
    }

    /// A slow genuine drag arrives as many small deltas. It must still get
    /// there rather than being filtered away one point at a time.
    func testASlowDragStillArrives() {
        var applied: CGFloat = 1200
        for step in 1...300 {
            let proposed = 1200 - CGFloat(step) * 0.9   // under the threshold per step
            if MapFrameStability.isRealChange(proposed, current: applied) {
                applied = MapFrameStability.settled(proposed)
            }
        }
        XCTAssertLessThan(applied, 935,
                          "a drag delivered in sub-point steps must not be ignored")
        XCTAssertGreaterThan(applied, 929, "and must not overshoot")
    }

    // MARK: - No map may opt out

    /// Every MKMapView in the app has to be the stable subclass.
    ///
    /// The fix is worthless on the next map someone adds. A bare
    /// `MKMapView()` anywhere reintroduces the jitter on that surface, and
    /// it took a day to identify the first time.
    func testNoMapIsConstructedWithoutFrameStability() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UI
            .deletingLastPathComponent()   // Unit
            .deletingLastPathComponent()   // AXTermTests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("AXTerm")

        let files = FileManager.default
            .enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        // A scan that reads nothing passes for the wrong reason.
        XCTAssertGreaterThan(files.count, 100, "did not find the app's sources")

        var offenders: [String] = []
        var scannedLines = 0
        for file in files {
            let raw = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in raw.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                // Comments name the trap to explain it; scan code only.
                let code = line.split(separator: "/").first.map(String.init) ?? ""
                guard !code.trimmingCharacters(in: .whitespaces).hasPrefix("///") else { continue }
                scannedLines += 1
                guard code.contains("MKMapView(") else { continue }
                offenders.append("\(file.lastPathComponent):\(number + 1) \(code.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThan(scannedLines, 10_000, "scanned almost nothing")
        XCTAssertTrue(offenders.isEmpty,
                      "construct StableFrameMapView, not MKMapView: \(offenders)")
    }

    /// ...and the stable subclass must actually still be a map, so the
    /// guard above cannot be satisfied by deleting the thing it guards.
    func testTheStableMapViewExistsAndIsAMapView() {
        let map = OfflineBasemapMapView.StableFrameMapView()
        XCTAssertTrue(map is MKMapView)
    }
}
