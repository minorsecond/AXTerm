import XCTest
@testable import AXTerm

/// What the map draws for the NWS layer (Docs/HazardLayers.md §1, §4).
final class HazardDrawingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_576_000)

    private func alert(_ event: String, expiresIn: TimeInterval = 3600, shaped: Bool = true) -> HazardFeature {
        var feature = HazardFeature(id: event, kind: NWSAlertFeed.kind(of: event), event: event,
                                    source: "NWS Boulder CO", fetchedAt: now)
        feature.expires = now.addingTimeInterval(expiresIn)
        if shaped {
            feature.geometry = .polygons([[[GreatCircle.Point(latitude: 39, longitude: -105),
                                            GreatCircle.Point(latitude: 39, longitude: -104),
                                            GreatCircle.Point(latitude: 40, longitude: -104)]]])
        }
        return feature
    }

    /// The most urgent draws last, on top.
    func testTheHighestPriorityDrawsOnTop() {
        let plan = HazardDrawing.plan([alert("Tornado Warning"), alert("Red Flag Warning")], now: now, stale: false)
        XCTAssertEqual(plan.items.map(\.id), ["Red Flag Warning", "Tornado Warning"])
    }

    func testACurrentAlertIsSolidInItsNWSColor() throws {
        let item = try XCTUnwrap(HazardDrawing.plan([alert("Red Flag Warning")], now: now, stale: false).items.first)
        XCTAssertEqual(item.hex, "FF1493")
        XCTAssertFalse(item.dashed)
        XCTAssertGreaterThan(item.fillAlpha, 0)
        XCTAssertEqual(item.strokeAlpha, HazardDrawing.currentStroke)
    }

    /// A stale copy is drawn fainter, so it reads as old.
    func testAStaleCopyIsFainter() throws {
        let current = try XCTUnwrap(HazardDrawing.plan([alert("Red Flag Warning")], now: now, stale: false).items.first)
        let stale = try XCTUnwrap(HazardDrawing.plan([alert("Red Flag Warning")], now: now, stale: true).items.first)
        XCTAssertLessThan(stale.strokeAlpha, current.strokeAlpha)
        XCTAssertLessThan(stale.fillAlpha, current.fillAlpha)
    }

    /// Expired: a faint dashed outline, no fill. Kept, never passed off as
    /// current.
    func testAnExpiredAlertIsADashedOutlineWithNoFill() throws {
        let item = try XCTUnwrap(HazardDrawing.plan([alert("Red Flag Warning", expiresIn: -60)],
                                                    now: now, stale: false).items.first)
        XCTAssertTrue(item.dashed)
        XCTAssertEqual(item.fillAlpha, 0)
        XCTAssertLessThan(item.strokeAlpha, HazardDrawing.currentStroke)
    }

    /// No shape yet (zones not loaded): not drawn, but counted for the list.
    func testAnAlertWithNoShapeIsCountedNotDrawn() {
        let plan = HazardDrawing.plan([alert("Red Flag Warning"), alert("Wind Advisory", shaped: false)],
                                      now: now, stale: false)
        XCTAssertEqual(plan.items.map(\.id), ["Red Flag Warning"])
        XCTAssertEqual(plan.unshaped, 1)
    }
}
