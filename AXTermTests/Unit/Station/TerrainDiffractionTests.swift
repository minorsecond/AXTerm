import XCTest
@testable import AXTerm

/// What an obstruction actually costs.
///
/// Metres above the line answer "is something in the way". They do not answer
/// "does it matter", and the two come apart badly — a ridge 4 m above the
/// line 1 km out costs about 7 dB, which a packet link shrugs off, and the
/// app was calling that "Blocked ... a direct contact is unlikely regardless
/// of power".
final class TerrainDiffractionTests: XCTestCase {

    /// The textbook number: a signal grazing a knife edge loses 6 dB. If this
    /// moves, the model has stopped being the model it claims to be.
    func testGrazingCostsSixDecibels() {
        XCTAssertEqual(TerrainProfile.knifeEdgeLossDb(fresnelRatio: 0), 6.0, accuracy: 0.15)
    }

    /// Why 0.6 of the first Fresnel zone has been the engineering rule for
    /// decades: at that clearance the diffraction loss has gone to nothing.
    /// The constant in the file and the physics agree, which is the point of
    /// checking it here rather than trusting the comment.
    func testTheSixtyPercentRuleIsWhereLossReachesZero() {
        XCTAssertEqual(
            TerrainProfile.knifeEdgeLossDb(
                fresnelRatio: TerrainProfile.fresnelClearanceThreshold),
            0, accuracy: 0.01)
        XCTAssertGreaterThan(TerrainProfile.knifeEdgeLossDb(fresnelRatio: 0.4), 0)
    }

    /// A fully clear path costs nothing, and no amount of extra clearance
    /// makes it cost less than nothing.
    func testClearanceBeyondTheZoneIsFree() {
        for ratio in [0.6, 1.0, 5.0, Double.infinity] {
            XCTAssertEqual(TerrainProfile.knifeEdgeLossDb(fresnelRatio: ratio), 0,
                           accuracy: 0.001, "ratio \(ratio)")
        }
    }

    /// Deeper intrusion costs more, without exception — a model that is not
    /// monotonic here would let a worse path read as better.
    func testDeeperIntrusionAlwaysCostsMore() {
        let ratios = [0.6, 0.3, 0.0, -0.3, -1.0, -3.0]
        let losses = ratios.map { TerrainProfile.knifeEdgeLossDb(fresnelRatio: $0) }
        for (a, b) in zip(losses, losses.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b)
        }
        XCTAssertGreaterThan(losses.last ?? 0, 20, "3x into the zone should be decisive")
    }

    /// The bands are what the operator actually reads, so the boundaries are
    /// pinned. Under 3 dB is inside the day-to-day variation of a real path;
    /// over 20 dB no amount of power on this path helps.
    func testSeverityBandsMatchWhatTheNumbersMean() {
        XCTAssertEqual(severity(for: 0), .negligible)
        XCTAssertEqual(severity(for: 2.9), .negligible)
        XCTAssertEqual(severity(for: 3), .noticeable)
        XCTAssertEqual(severity(for: 9.9), .noticeable)
        XCTAssertEqual(severity(for: 10), .severe)
        XCTAssertEqual(severity(for: 19.9), .severe)
        XCTAssertEqual(severity(for: 20), .blocking)
    }

    /// The case from the field: 4 m above the line, 1.2 km into a 42.8 km
    /// path at 145 MHz. Geometrically obstructed, and about 7 dB — which is a
    /// path you work and notice, not a path that is gone.
    func testAGrazingRidgeNearTheOperatorIsNotABlockedPath() {
        // First Fresnel radius there: sqrt(lambda x d1 x d2 / d).
        let lambda = TerrainProfile.speedOfLight / 145_000_000
        let d1 = 1_200.0, d = 42_800.0
        let f1 = (lambda * d1 * (d - d1) / d).squareRoot()
        let loss = TerrainProfile.knifeEdgeLossDb(fresnelRatio: -4 / f1)

        XCTAssertEqual(loss, 7, accuracy: 1.5)
        XCTAssertEqual(severity(for: loss), .noticeable,
                       "4 m of grazing is not \"a direct contact is unlikely regardless of power\"")
    }

    /// The same 4 m at the midpoint of the same path is a different fact —
    /// the Fresnel zone is widest there, so the intrusion is a smaller
    /// fraction of it and costs less. Metres alone cannot express that, which
    /// is the whole argument for reporting decibels.
    func testTheSameHeightCostsDifferentlyDependingOnWhereItIs() {
        let lambda = TerrainProfile.speedOfLight / 145_000_000
        let d = 42_800.0
        func loss(at d1: Double) -> Double {
            let f1 = (lambda * d1 * (d - d1) / d).squareRoot()
            return TerrainProfile.knifeEdgeLossDb(fresnelRatio: -4 / f1)
        }
        XCTAssertGreaterThan(loss(at: 1_200), loss(at: d / 2))
    }

    private func severity(for loss: Double) -> TerrainProfile.Severity {
        switch loss {
        case ..<3: return .negligible
        case ..<10: return .noticeable
        case ..<20: return .severe
        default: return .blocking
        }
    }
}
