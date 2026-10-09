import XCTest
@testable import AXTerm

/// How a movement trail is drawn (operator, 2026-10-09: "make the trails
/// really useful and aesthetic"). Two trails along US-285 met nearly end to
/// end in the same green and read as one broken line; nothing said whose
/// was whose, which end was now, or where the line was a guess.
final class TrailPlanTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_576_000)

    private func p(_ lat: Double, _ lon: Double) -> GreatCircle.Point {
        GreatCircle.Point(latitude: lat, longitude: lon)
    }

    private func minutes(_ m: [Double]) -> [Date] { m.map { t0.addingTimeInterval($0 * 60) } }

    private var drive: [GreatCircle.Point] { [p(39.52, -105.31), p(39.58, -105.25), p(39.62, -105.19), p(39.64, -105.13)] }

    /// Strong at the station's end, faint at its oldest fix: which way it
    /// went, and which end belongs to the marker.
    func testATrailFadesFromItsOldestFixToNow() throws {
        let plan = TrailPlan.plan(points: drive, times: minutes([0, 3, 6, 9]), emphasis: .normal, baseAlpha: 1)
        let piece = try XCTUnwrap(plan.pieces.first)
        XCTAssertEqual(plan.pieces.count, 1)
        XCTAssertFalse(piece.dashed)
        XCTAssertEqual(piece.points, drive)
        XCTAssertEqual(piece.endAlpha, 1, accuracy: 1e-9)
        XCTAssertLessThan(piece.startAlpha, 0.3)
    }

    /// The oldest end stays faint but keeps its color: at 15% a vehicle's
    /// orange read as gray on the basemap and passed for another station's
    /// trail (Station C, 2026-10-09).
    func testTheOldestEndKeepsEnoughColorToRecognize() throws {
        let plan = TrailPlan.plan(points: drive, times: minutes([0, 3, 6, 9]), emphasis: .normal, baseAlpha: 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(plan.pieces.first).startAlpha, 0.25)
    }

    /// More than ten minutes between fixes: the straight line is a guess, not
    /// the road, so it is dashed and faint between solid stretches.
    func testALongGapBetweenFixesIsDashed() {
        let plan = TrailPlan.plan(points: drive, times: minutes([0, 3, 18, 21]), emphasis: .normal, baseAlpha: 1)
        XCTAssertEqual(plan.pieces.map(\.dashed), [false, true, false])
        XCTAssertEqual(plan.pieces.map(\.points.count), [2, 2, 2])
        XCTAssertEqual(plan.pieces[1].points, [drive[1], drive[2]])
    }

    /// The fade runs by time across the pieces, so the dashed stretch sits
    /// between its neighbors' alphas rather than restarting.
    func testTheFadeIsContinuousAcrossPieces() {
        let plan = TrailPlan.plan(points: drive, times: minutes([0, 3, 18, 21]), emphasis: .normal, baseAlpha: 1)
        XCTAssertEqual(plan.pieces[0].endAlpha, plan.pieces[1].startAlpha * (1 / TrailPlan.gapAlphaFactor), accuracy: 1e-9)
        XCTAssertLessThan(plan.pieces[0].startAlpha, plan.pieces[2].endAlpha)
    }

    /// Selected: thicker, full strength, with each beacon fix marked.
    func testTheSelectedTrailStandsOutWithItsFixes() {
        let selected = TrailPlan.plan(points: drive, times: minutes([0, 3, 6, 9]), emphasis: .selected, baseAlpha: 0.6)
        let normal = TrailPlan.plan(points: drive, times: minutes([0, 3, 6, 9]), emphasis: .normal, baseAlpha: 0.6)
        XCTAssertGreaterThan(selected.pieces[0].width, normal.pieces[0].width)
        XCTAssertEqual(selected.pieces[0].endAlpha, 1, accuracy: 1e-9, "a selected trail is drawn at full strength")
        XCTAssertEqual(selected.fixes, drive)
        XCTAssertTrue(normal.fixes.isEmpty, "fix dots only for the selection, or the map fills with dots")
    }

    /// Another station selected: this trail steps back.
    func testOtherTrailsDimWhileOneIsSelected() {
        let dimmed = TrailPlan.plan(points: drive, times: minutes([0, 3, 6, 9]), emphasis: .dimmed, baseAlpha: 1)
        let normal = TrailPlan.plan(points: drive, times: minutes([0, 3, 6, 9]), emphasis: .normal, baseAlpha: 1)
        XCTAssertLessThan(dimmed.pieces[0].endAlpha, normal.pieces[0].endAlpha)
        XCTAssertLessThan(dimmed.pieces[0].width, normal.pieces[0].width)
    }

    func testFewerThanTwoFixesDrawNothing() {
        XCTAssertTrue(TrailPlan.plan(points: [drive[0]], times: minutes([0]), emphasis: .selected, baseAlpha: 1)
            .pieces.isEmpty)
    }

    /// Recency is opacity, as on the markers.
    func testRecencyIsOpacityLikeTheMarkers() {
        XCTAssertEqual(TrailPlan.baseAlpha(for: .good), 1)
        XCTAssertGreaterThan(TrailPlan.baseAlpha(for: .fair), TrailPlan.baseAlpha(for: .poor))
        XCTAssertGreaterThan(TrailPlan.baseAlpha(for: .poor), TrailPlan.baseAlpha(for: .unknown))
    }

    /// Whose trail: the emphasis follows the selection.
    func testTheEmphasisFollowsTheSelection() {
        XCTAssertEqual(TrailPlan.emphasis(for: "K0TOC-9", selection: "K0TOC-9"), .selected)
        XCTAssertEqual(TrailPlan.emphasis(for: "KF0VXO-9", selection: "K0TOC-9"), .dimmed)
        XCTAssertEqual(TrailPlan.emphasis(for: "KF0VXO-9", selection: nil), .normal)
    }

    /// The track carries its fix times, so the plan can find the gaps.
    func testATrailKeepsItsFixTimes() throws {
        var station = Station(call: "K0TOC-9")
        station.track = zip(drive, minutes([0, 3, 18, 21])).map {
            Station.APRSFix(latitude: $0.latitude, longitude: $0.longitude, timestamp: $1)
        }
        let track = try XCTUnwrap(MapTrack.trails(stations: [station], placedIDs: ["K0TOC-9"], selection: nil,
                                                  showsAll: true, windowMinutes: 0).first)
        XCTAssertEqual(track.times, minutes([0, 3, 18, 21]))
    }

    // MARK: - Color

    /// A trail wears its marker's color: the type color for a station that
    /// beaconed a symbol (a vehicle's trail is the vehicle orange), the
    /// recency color for one with none. Before, every trail was the recency
    /// green, while the markers were colored by type.
    func testATrailWearsItsMarkersColor() {
        let car = APRSMapSymbol(table: "/", code: ">")
        XCTAssertEqual(OfflineBasemapMapView.trailTint(symbol: car, signal: .good),
                       OfflineBasemapMapView.Coordinator.typeColour(forCode: ">"))
        XCTAssertEqual(OfflineBasemapMapView.trailTint(symbol: nil, signal: .fair),
                       OfflineBasemapMapView.Coordinator.tint(forSignal: .fair))
        XCTAssertEqual(OfflineBasemapMapView.trailTint(symbol: nil, signal: nil), .systemGray)
    }
}
