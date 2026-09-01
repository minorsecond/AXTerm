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

/// The approximation, checked against the thing it approximates.
///
/// P.526's J(v) is a closed-form fit to the Fresnel-Kirchhoff diffraction
/// integral. Asserting it against hand-picked constants only shows it agrees
/// with whoever picked them; integrating the actual Fresnel integrals and
/// comparing is an independent implementation of the same physics, and it is
/// the difference between "the number looks right" and "the number is right".
///
/// The integrals are computed here by Simpson's rule rather than imported,
/// deliberately: a reference that shares code with the thing under test
/// checks nothing.
final class KnifeEdgeApproximationTests: XCTestCase {

    /// |E/E0| in dB from the Fresnel-Kirchhoff integral, evaluated directly.
    ///
    /// C(v) and S(v) are integrated over 0...v, which is short and smooth,
    /// and the remainder to infinity comes from C(∞) = S(∞) = ½ — a standard
    /// result, not a number borrowed from the code under test. Integrating
    /// v...∞ directly instead leaves an oscillating tail that truncation
    /// cannot resolve: cutting it at t = 40 costs a whole decibel by v = 3,
    /// which would have made this reference less accurate than the
    /// approximation it is here to judge.
    private func exactLossDb(_ v: Double) -> Double {
        let steps = 20_000
        let h = v / Double(steps)
        var c = 0.0, s = 0.0
        for i in 0...steps {
            let t = Double(i) * h
            let weight: Double = (i == 0 || i == steps) ? 1 : (i % 2 == 1 ? 4 : 2)
            c += weight * cos(.pi * t * t / 2)
            s += weight * sin(.pi * t * t / 2)
        }
        let cv = 0.5 - c * h / 3
        let sv = 0.5 - s * h / 3
        // E/E0 = (1+j)/2 x [C(v→∞) - jS(v→∞)].
        let real = 0.5 * (cv + sv)
        let imaginary = 0.5 * (cv - sv)
        return -20 * log10((real * real + imaginary * imaginary).squareRoot())
    }

    /// Across the whole range the app reports, the closed form tracks the
    /// integral to a tenth of a decibel — far inside the uncertainty of the
    /// antenna heights it is fed.
    func testTheClosedFormTracksTheFresnelIntegral() {
        for step in -3...20 {
            let v = Double(step) * 0.25
            let approximate = TerrainProfile.knifeEdgeLossDb(fresnelRatio: -v / 2.0.squareRoot())
            XCTAssertEqual(approximate, exactLossDb(v), accuracy: 0.2,
                           "v = \(String(format: "%.2f", v))")
        }
    }

    /// Grazing costs 6 dB. It falls out of the integral, not out of the fit.
    func testTheIntegralGivesTheTextbookGrazingLoss() {
        XCTAssertEqual(exactLossDb(0), 6.02, accuracy: 0.05)
    }

    /// Where the 0.78 cutoff in the model comes from: it is where the exact
    /// curve crosses zero, at about 0.55 of the first Fresnel radius.
    func testTheCutoffIsWhereTheExactCurveCrossesZero() {
        XCTAssertEqual(exactLossDb(-0.78), 0, accuracy: 0.05)
    }

    /// Past that crossing the exact solution goes *negative* — a clearance of
    /// 0.6 F1 shows about 0.4 dB of enhancement, and 0.7 F1 about 1 dB,
    /// because the diffracted and direct fields add. Real, and deliberately
    /// not modelled: the app clamps to zero, so it never credits a ridge with
    /// improving a path. Overstating loss costs an operator a contact they
    /// might have made; claiming gain from an obstruction costs them trust in
    /// everything else the page says.
    func testTheModelDeclinesToClaimGainTheExactSolutionAllows() {
        XCTAssertLessThan(exactLossDb(-0.6 * 2.0.squareRoot()), -0.2)
        XCTAssertLessThan(exactLossDb(-1.0), -0.5)

        XCTAssertEqual(TerrainProfile.knifeEdgeLossDb(fresnelRatio: 0.6), 0)
        XCTAssertEqual(TerrainProfile.knifeEdgeLossDb(fresnelRatio: 0.707), 0)
    }
}

/// What the single-edge model cannot see.
final class MultipleObstructionTests: XCTestCase {

    private struct TwoRidges: ElevationSampling {
        let origin: GreatCircle.Point
        let destination: GreatCircle.Point
        func elevation(at point: GreatCircle.Point) -> Double? {
            let total = GreatCircle.kilometres(from: origin, to: destination)
            guard total > 0 else { return 0 }
            let along = GreatCircle.kilometres(from: origin, to: point) / total
            for centre in [0.3, 0.7] where abs(along - centre) < 0.08 {
                return 600 * (1 - abs(along - centre) / 0.08)
            }
            return 0
        }
    }

    private struct OneRidge: ElevationSampling {
        let origin: GreatCircle.Point
        let destination: GreatCircle.Point
        func elevation(at point: GreatCircle.Point) -> Double? {
            let total = GreatCircle.kilometres(from: origin, to: destination)
            guard total > 0 else { return 0 }
            let along = GreatCircle.kilometres(from: origin, to: point) / total
            return abs(along - 0.5) < 0.08 ? 600 * (1 - abs(along - 0.5) / 0.08) : 0
        }
    }

    private let here = GreatCircle.Point(latitude: 39.6, longitude: -104.9)
    private let there = GreatCircle.Point(latitude: 39.6, longitude: -104.3)

    private func profile(_ sampler: ElevationSampling) -> TerrainProfile {
        // High antennas on purpose. At 10 m the earth's own bulge sags the
        // ground into the path across the whole middle, joining the two
        // ridges into one continuous obstruction — a true result, and not the
        // one this test is about.
        TerrainProfile.between(origin: here, destination: there,
                               originHeight: 250, destinationHeight: 250,
                               frequencyHz: 145_000_000, sampler: sampler)
    }

    /// One ridge is one knife edge, and the figure is an estimate.
    func testASingleRidgeIsReportedAsAnEstimate() {
        let single = profile(OneRidge(origin: here, destination: there))
        XCTAssertEqual(single.obstructionCount, 1)
        XCTAssertFalse(single.lossIsAFloor)
        XCTAssertNil(single.lossCaveat)
    }

    /// Two ridges cost more than the worse of them — the second diffracts
    /// what the first left — and this model only sees the worst point. Saying
    /// the number is a floor is the difference between a model and a guess
    /// wearing a unit.
    func testTwoRidgesAreReportedAsAFloor() {
        let double = profile(TwoRidges(origin: here, destination: there))
        XCTAssertEqual(double.obstructionCount, 2)
        XCTAssertTrue(double.lossIsAFloor)
        XCTAssertEqual(double.lossCaveat?.contains("2 separate obstructions"), true)
    }

    /// A clear path has nothing to caveat.
    func testAClearPathCarriesNoCaveat() {
        let clear = TerrainProfile.between(
            origin: here, destination: there, originHeight: 300, destinationHeight: 300,
            frequencyHz: 145_000_000, sampler: FlatGround())
        XCTAssertEqual(clear.obstructionCount, 0)
        XCTAssertNil(clear.lossCaveat)
    }

    private struct FlatGround: ElevationSampling {
        func elevation(at point: GreatCircle.Point) -> Double? { 0 }
    }
}

/// Finding every obstruction, not just the one that decides the verdict.
///
/// The caption counts them, so the chart has to be able to draw them all:
/// telling an operator there are "2 separate obstructions" while marking one
/// leaves them hunting for a second ridge with no idea where it is.
final class ObstructionLocationTests: XCTestCase {

    private let here = GreatCircle.Point(latitude: 39.6, longitude: -104.9)
    private let there = GreatCircle.Point(latitude: 39.6, longitude: -104.3)

    private struct Ridges: ElevationSampling {
        let origin: GreatCircle.Point
        let destination: GreatCircle.Point
        /// Fractions along the path, and how high each peak stands.
        let peaks: [(at: Double, height: Double)]

        func elevation(at point: GreatCircle.Point) -> Double? {
            let total = GreatCircle.kilometres(from: origin, to: destination)
            guard total > 0 else { return 0 }
            let along = GreatCircle.kilometres(from: origin, to: point) / total
            for peak in peaks where abs(along - peak.at) < 0.06 {
                return peak.height * (1 - abs(along - peak.at) / 0.06)
            }
            return 0
        }
    }

    private func profile(_ peaks: [(at: Double, height: Double)]) -> TerrainProfile {
        TerrainProfile.between(
            origin: here, destination: there,
            originHeight: 250, destinationHeight: 250,
            frequencyHz: 145_000_000,
            sampler: Ridges(origin: here, destination: there, peaks: peaks))
    }

    /// One local worst point per obstruction, in path order, and the count
    /// agrees with what the caption says.
    func testEachObstructionIsFoundOnce() {
        let two = profile([(0.3, 600), (0.7, 600)])
        XCTAssertEqual(two.obstructions.count, 2)
        XCTAssertEqual(two.obstructions.count, two.obstructionCount)

        let fractions = two.obstructions.map { $0.distanceMetres / two.totalMetres }
        XCTAssertEqual(fractions[0], 0.3, accuracy: 0.05)
        XCTAssertEqual(fractions[1], 0.7, accuracy: 0.05)
        XCTAssertLessThan(fractions[0], fractions[1], "path order, not severity order")
    }

    /// Each entry is the worst point of its own stretch, so a marker lands on
    /// the peak rather than on the shoulder where the stretch began.
    func testEachEntryIsTheWorstPointOfItsOwnRidge() {
        let uneven = profile([(0.25, 500), (0.65, 900)])
        XCTAssertEqual(uneven.obstructions.count, 2)

        let taller = uneven.obstructions.max { $0.effectiveElevation < $1.effectiveElevation }
        XCTAssertEqual((taller?.distanceMetres ?? 0) / uneven.totalMetres, 0.65, accuracy: 0.05)

        // The verdict comes from one of these, so the chart's full treatment
        // always has an entry to attach to.
        let worst = uneven.obstructions.min { $0.fresnelRatio < $1.fresnelRatio }
        XCTAssertNotNil(worst)
    }

    /// A single ridge is one entry, and a clear path is none.
    func testTheSimpleCasesStaySimple() {
        XCTAssertEqual(profile([(0.5, 600)]).obstructions.count, 1)
        XCTAssertTrue(profile([]).obstructions.isEmpty)
    }
}
