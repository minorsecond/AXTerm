import XCTest
@testable import AXTerm

/// What the map says when the terrain pass finds nothing to draw.
///
/// The case that matters: in rolling ground at modest antenna heights every
/// untried path can be genuinely blocked. The map then draws nothing, which
/// is indistinguishable from a broken feature unless the summary says
/// otherwise. This is the real Denver-metro result — the terrain climbs from
/// the Platte to Parker, so a line between two 10 m antennas has ground above
/// it, and every forecast came back blocked.
final class NetworkInsightSnapshotTests: XCTestCase {

    private func blocked(_ from: String, _ to: String, by metres: Double) -> PredictedPath {
        PredictedPath(from: from, to: to,
                      outlook: .blocked(byMetres: metres, atMetres: 6000),
                      distanceKilometres: 12)
    }

    private func marginal(_ from: String, _ to: String) -> PredictedPath {
        PredictedPath(from: from, to: to,
                      outlook: .marginal(worstFresnelRatio: 0.3),
                      distanceKilometres: 12)
    }

    func testDrawablePredictionsExcludeBlockedOnes() {
        var snapshot = NetworkInsightModel.Snapshot()
        snapshot.predictions = [blocked("A", "B", by: 4), marginal("C", "D")]
        XCTAssertEqual(snapshot.drawablePredictions.count, 1)
        XCTAssertEqual(snapshot.drawablePredictions.first?.from, "C")
    }

    /// The near miss is the actionable one — four metres of mast, not a
    /// hundred and seventy.
    func testClosestBlockedIsTheSmallestObstruction() {
        var snapshot = NetworkInsightModel.Snapshot()
        snapshot.predictions = [
            blocked("GOLDEN", "MORRISON", by: 173),
            blocked("AURORA", "DENVER", by: 4.1),
            blocked("DENVER", "PARKER", by: 31),
        ]
        XCTAssertEqual(snapshot.closestBlocked?.from, "AURORA")
        XCTAssertEqual(snapshot.closestBlocked?.blockedByMetres ?? 0, 4.1, accuracy: 0.001)
    }

    func testNoBlockedPathsMeansNoNearMiss() {
        var snapshot = NetworkInsightModel.Snapshot()
        snapshot.predictions = [marginal("A", "B")]
        XCTAssertNil(snapshot.closestBlocked)
    }

    /// Terrain missing entirely is a different story from terrain that
    /// answered "no", and the two must not collapse into one silence.
    func testUnavailableTerrainIsDistinctFromAnEmptyResult() {
        var unavailable = NetworkInsightModel.Snapshot()
        unavailable.terrainUnavailable = true
        XCTAssertTrue(unavailable.predictions.isEmpty)
        XCTAssertTrue(unavailable.terrainUnavailable)

        let answered = NetworkInsightModel.Snapshot()
        XCTAssertFalse(answered.terrainUnavailable)
    }
}
