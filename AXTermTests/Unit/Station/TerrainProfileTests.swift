import XCTest
@testable import AXTerm

/// Terrain path analysis.
///
/// Tested against synthetic terrain — a flat plain, a single ridge, a known
/// summit — because the point is to pin the *physics*, and a fixture from a
/// real download would only pin whatever that download happened to contain.
///
/// The physical claims are checked against textbook values, not against the
/// implementation's own output. A path-profile tool that is self-consistent
/// and wrong is worse than no tool, because an operator will trust it.
final class TerrainProfileTests: XCTestCase {

    // MARK: - Synthetic terrain

    /// Flat ground at a fixed elevation.
    private struct Plain: ElevationSampling {
        var metres: Double
        func elevation(at point: GreatCircle.Point) -> Double? { metres }
    }

    /// A plain with one ridge, described by where it is along the path.
    private struct Ridge: ElevationSampling {
        var base: Double
        var peak: Double
        var origin: GreatCircle.Point
        var destination: GreatCircle.Point
        /// Fraction along the path where the ridge is, and its half-width.
        var atFraction: Double
        var halfWidthFraction: Double

        func elevation(at point: GreatCircle.Point) -> Double? {
            let total = GreatCircle.kilometres(from: origin, to: destination)
            guard total > 0 else { return base }
            let along = GreatCircle.kilometres(from: origin, to: point) / total
            let distance = abs(along - atFraction)
            guard distance < halfWidthFraction else { return base }
            // Triangular ridge, so the peak is exactly `peak` at the centre.
            return base + (peak - base) * (1 - distance / halfWidthFraction)
        }
    }

    /// A valley between two ridges — the shape of a genuinely clear VHF
    /// path, and the reason gateways sit on hilltops.
    private struct Valley: ElevationSampling {
        var ridge: Double
        var floor: Double
        var origin: GreatCircle.Point
        var destination: GreatCircle.Point

        func elevation(at point: GreatCircle.Point) -> Double? {
            let total = GreatCircle.kilometres(from: origin, to: destination)
            guard total > 0 else { return ridge }
            let along = GreatCircle.kilometres(from: origin, to: point) / total
            // Drops to the floor across the middle 80% of the path.
            let depth = sin(min(max(along, 0), 1) * .pi)
            return ridge - (ridge - floor) * depth
        }
    }

    /// Terrain with a hole in it.
    private struct Patchy: ElevationSampling {
        var metres: Double
        var missingFrom: Double
        var missingTo: Double
        var origin: GreatCircle.Point
        var destination: GreatCircle.Point

        func elevation(at point: GreatCircle.Point) -> Double? {
            let total = GreatCircle.kilometres(from: origin, to: destination)
            guard total > 0 else { return metres }
            let along = GreatCircle.kilometres(from: origin, to: point) / total
            return (along > missingFrom && along < missingTo) ? nil : metres
        }
    }

    private func point(_ lat: Double, _ lon: Double) -> GreatCircle.Point {
        GreatCircle.Point(latitude: lat, longitude: lon)
    }

    /// Roughly 20 km apart, east–west at Denver's latitude.
    private var near: (GreatCircle.Point, GreatCircle.Point) {
        (point(39.74, -104.99), point(39.74, -104.755))
    }

    /// Roughly 100 km apart.
    private var far: (GreatCircle.Point, GreatCircle.Point) {
        (point(39.74, -104.99), point(39.74, -103.82))
    }

    // MARK: - Earth curvature

    /// The correction that makes this tool honest. Two 10 m antennas 100 km
    /// apart over a flat plain **cannot** see each other — the planet is in
    /// the way — and a straight line drawn on a map says they can.
    func testTwoLowAntennasCannotSeeEachOtherAcrossAHundredKilometresOfFlatGround() {
        let (a, b) = far
        let profile = TerrainProfile.between(
            origin: a, destination: b, originHeight: 10, destinationHeight: 10,
            frequencyHz: 145_050_000, sampler: Plain(metres: 1600))

        guard case .obstructed = profile.verdict else {
            return XCTFail("the earth's curvature should block this: \(profile.verdict)")
        }
    }

    /// Two stations on ridges across a valley — the shape of a genuinely
    /// clear VHF path, and the reason gateways sit on hilltops.
    func testTwoStationsAcrossAValleyHaveAClearPath() {
        let (a, b) = near
        let profile = TerrainProfile.between(
            origin: a, destination: b, originHeight: 10, destinationHeight: 10,
            frequencyHz: 145_050_000,
            sampler: Valley(ridge: 1600, floor: 1300, origin: a, destination: b))

        guard case .clear(let ratio) = profile.verdict else {
            return XCTFail("a valley path should be clear: \(profile.verdict)")
        }
        XCTAssertGreaterThanOrEqual(ratio, TerrainProfile.fresnelClearanceThreshold)
    }

    /// A finding worth pinning, because it is counter-intuitive and it is why
    /// so many "line of sight" VHF paths disappoint: at 145 MHz the first
    /// Fresnel zone at the middle of a 20 km path is over 100 m across, so
    /// two 10-metre antennas over flat ground clear only about 4% of it.
    ///
    /// Geometrically there is line of sight. In practice the path is
    /// diffraction-limited — which is exactly the "answers but struggles"
    /// signature in the link-quality data.
    func testLowAntennasOverFlatGroundAreMarginalEvenAtModestRange() {
        let (a, b) = near
        let profile = TerrainProfile.between(
            origin: a, destination: b, originHeight: 10, destinationHeight: 10,
            frequencyHz: 145_050_000, sampler: Plain(metres: 1600))

        guard case .marginal(let ratio, _) = profile.verdict else {
            return XCTFail("expected marginal, got \(profile.verdict)")
        }
        XCTAssertGreaterThan(ratio, 0, "there is still line of sight")
        XCTAssertLessThan(ratio, 0.1)
    }

    /// The bulge is greatest at mid-path and zero at the ends, which is what
    /// makes an obstruction in the middle matter most.
    func testTheBulgeIsLargestAtMidPath() {
        let total = 100_000.0
        let middle = TerrainProfile.earthBulge(d1: total / 2, d2: total / 2)
        let quarter = TerrainProfile.earthBulge(d1: total / 4, d2: 3 * total / 4)

        XCTAssertGreaterThan(middle, quarter)
        XCTAssertEqual(TerrainProfile.earthBulge(d1: 0, d2: total), 0)
        XCTAssertEqual(TerrainProfile.earthBulge(d1: total, d2: 0), 0)

        // 100 km, mid-path, k=4/3: (50000 × 50000) / (2 × 4/3 × 6371008.8) ≈ 147 m.
        XCTAssertEqual(middle, 147, accuracy: 2)
    }

    /// The familiar 4.12 × √h radio horizon, which falls out of the same
    /// effective-radius factor. Checked against the textbook value so the
    /// factor cannot silently drift.
    func testRadioHorizonMatchesTheTextbookFormula() {
        for height in [10.0, 30.0, 100.0] {
            let expected = 4.12 * height.squareRoot()
            XCTAssertEqual(TerrainProfile.radioHorizonKilometres(heightMetres: height),
                           expected, accuracy: expected * 0.01, "at \(height) m")
        }
        XCTAssertEqual(TerrainProfile.radioHorizonKilometres(heightMetres: 0), 0)
    }

    // MARK: - Obstruction

    /// A ridge above the line blocks the path, and the report says where and
    /// by how much — the two things that decide what to do about it.
    func testARidgeAboveTheLineBlocksThePath() {
        let (a, b) = near
        let profile = TerrainProfile.between(
            origin: a, destination: b, originHeight: 10, destinationHeight: 10,
            frequencyHz: 145_050_000,
            sampler: Ridge(base: 1600, peak: 2000, origin: a, destination: b,
                           atFraction: 0.5, halfWidthFraction: 0.1))

        guard case .obstructed(let by, let at) = profile.verdict else {
            return XCTFail("a 400 m ridge should block a 20 km path: \(profile.verdict)")
        }
        XCTAssertGreaterThan(by, 300)
        XCTAssertEqual(at, profile.totalMetres / 2, accuracy: profile.totalMetres * 0.05)
    }

    /// The endpoints are excluded from the verdict. The antennas sit on their
    /// own ground, so clearance there is exactly the antenna height and the
    /// Fresnel radius is zero — including them would report every path as
    /// obstructed by its own mast.
    func testAPathIsNotObstructedByItsOwnAntennaMasts() {
        // Built directly rather than from terrain: the endpoints are where
        // clearance equals the antenna height and the Fresnel radius is zero,
        // so `fresnelRatio` there is meaningless by construction.
        let ends = TerrainProfile.Sample(
            distanceMetres: 0, coordinate: point(39, -105),
            groundElevation: 1600, effectiveElevation: 1600,
            lineHeight: 1600, fresnelRadius: 0)
        let middle = TerrainProfile.Sample(
            distanceMetres: 10_000, coordinate: point(39, -104.9),
            groundElevation: 1200, effectiveElevation: 1206,
            lineHeight: 1600, fresnelRadius: 100)

        // Zero clearance at both ends, huge clearance in the middle.
        guard case .clear = TerrainProfile.verdict(for: [ends, middle, ends]) else {
            return XCTFail("the endpoints should not decide the verdict")
        }

        // And a path with nothing but endpoints has no interior to judge.
        guard case .clear = TerrainProfile.verdict(for: [ends, ends]) else {
            return XCTFail("a two-sample path should not report an obstruction")
        }
    }

    // MARK: - Fresnel

    /// A path that clears the ground but intrudes into the Fresnel zone is
    /// the "answers but struggles" case — the one the link-quality data shows
    /// with no explanation attached.
    func testAPathThatClearsGeometricallyCanStillBeMarginal() {
        let (a, b) = near
        // Tall towers, so there is comfortable line of sight, with a ridge
        // that rises into the Fresnel zone without reaching the line itself.
        let profile = TerrainProfile.between(
            origin: a, destination: b, originHeight: 100, destinationHeight: 100,
            frequencyHz: 145_050_000,
            sampler: Ridge(base: 1300, peak: 1360, origin: a, destination: b,
                           atFraction: 0.5, halfWidthFraction: 0.15))

        guard case .marginal(let ratio, _) = profile.verdict else {
            return XCTFail("expected marginal, got \(profile.verdict)")
        }
        XCTAssertGreaterThan(ratio, 0, "there is still line of sight")
        XCTAssertLessThan(ratio, TerrainProfile.fresnelClearanceThreshold)
    }

    /// The Fresnel zone is wider at lower frequencies, so the same terrain is
    /// harsher on 145 MHz than on 440. An operator choosing a band needs this
    /// to be right, and it is the kind of thing that inverts silently.
    func testTheFresnelZoneIsWiderAtLowerFrequencies() {
        let vhf = TerrainProfile.fresnelRadius(
            wavelength: TerrainProfile.speedOfLight / 145_050_000, d1: 10_000, d2: 10_000)
        let uhf = TerrainProfile.fresnelRadius(
            wavelength: TerrainProfile.speedOfLight / 440_000_000, d1: 10_000, d2: 10_000)

        XCTAssertGreaterThan(vhf, uhf)
        // λ ≈ 2.0668 m; √(2.0668 × 10000 × 10000 / 20000) = √10334 ≈ 101.7 m.
        // Over a hundred metres across at mid-path — which is why so many
        // "line of sight" VHF paths are marginal in practice.
        XCTAssertEqual(vhf, 101.7, accuracy: 0.5)
    }

    /// Zero at the endpoints, widest at mid-path — the shape of the ellipsoid.
    func testTheFresnelRadiusIsZeroAtTheEndsAndWidestInTheMiddle() {
        let wavelength = 2.0
        XCTAssertEqual(TerrainProfile.fresnelRadius(wavelength: wavelength, d1: 0, d2: 20_000), 0)
        XCTAssertEqual(TerrainProfile.fresnelRadius(wavelength: wavelength, d1: 20_000, d2: 0), 0)

        let middle = TerrainProfile.fresnelRadius(wavelength: wavelength, d1: 10_000, d2: 10_000)
        let quarter = TerrainProfile.fresnelRadius(wavelength: wavelength, d1: 5_000, d2: 15_000)
        XCTAssertGreaterThan(middle, quarter)
    }

    /// 60% is the long-standing engineering threshold; below it diffraction
    /// loss becomes significant. Pinned so it cannot drift into meaninglessness.
    func testTheClearanceThresholdIsSixtyPercent() {
        XCTAssertEqual(TerrainProfile.fresnelClearanceThreshold, 0.6, accuracy: 1e-9)
    }

    // MARK: - Missing data

    /// A gap in the elevation data is exactly where the ridge might be, so no
    /// verdict is given. Reading a hole as sea level would turn an unknown
    /// mountain into a clear path — the most dangerous way to be wrong here.
    func testAGapInTheDataProducesNoVerdictRatherThanAGuess() {
        let (a, b) = near
        let profile = TerrainProfile.between(
            origin: a, destination: b, originHeight: 10, destinationHeight: 10,
            frequencyHz: 145_050_000,
            sampler: Patchy(metres: 1600, missingFrom: 0.4, missingTo: 0.6,
                            origin: a, destination: b))

        guard case .unknown(let reason) = profile.verdict else {
            return XCTFail("expected unknown, got \(profile.verdict)")
        }
        XCTAssertTrue(reason.contains("missing"), reason)
        XCTAssertFalse(profile.verdict.isUsable)
    }

    func testMissingDataAtAnEndpointIsReported() {
        let (a, b) = near
        let profile = TerrainProfile.between(
            origin: a, destination: b, originHeight: 10, destinationHeight: 10,
            frequencyHz: 145_050_000,
            sampler: Patchy(metres: 1600, missingFrom: -1, missingTo: 0.01,
                            origin: a, destination: b))

        guard case .unknown = profile.verdict else {
            return XCTFail("expected unknown, got \(profile.verdict)")
        }
    }

    // MARK: - Sampling

    func testSamplesRunFromEndToEnd() {
        let (a, b) = near
        let profile = TerrainProfile.between(
            origin: a, destination: b, originHeight: 10, destinationHeight: 10,
            frequencyHz: 145_050_000, sampler: Plain(metres: 1600), sampleCount: 64)

        XCTAssertEqual(profile.samples.count, 64)
        XCTAssertEqual(profile.samples.first?.distanceMetres ?? -1, 0, accuracy: 1)
        XCTAssertEqual(profile.samples.last?.distanceMetres ?? -1,
                       profile.totalMetres, accuracy: 1)
    }

    /// Sampled along the great circle, not a straight line in latitude and
    /// longitude. Over 100 km the two differ by hundreds of metres, and a
    /// profile of the wrong line is a profile of the wrong ridge.
    func testThePathIsSampledAlongTheGreatCircle() {
        // A long east–west path at high latitude, where the difference is
        // largest: the great circle bows toward the pole.
        let a = GreatCircle.Point(latitude: 60, longitude: -140)
        let b = GreatCircle.Point(latitude: 60, longitude: -100)
        let middle = GreatCircle.interpolate(from: a, to: b, fraction: 0.5)

        XCTAssertGreaterThan(middle.latitude, 60.5,
                             "the great circle should bow poleward, not follow the parallel")
        XCTAssertEqual(middle.longitude, -120, accuracy: 0.001)
    }

    func testInterpolationHitsBothEnds() {
        let (a, b) = far
        let start = GreatCircle.interpolate(from: a, to: b, fraction: 0)
        let end = GreatCircle.interpolate(from: a, to: b, fraction: 1)

        XCTAssertEqual(start.latitude, a.latitude, accuracy: 1e-9)
        XCTAssertEqual(start.longitude, a.longitude, accuracy: 1e-9)
        XCTAssertEqual(end.latitude, b.latitude, accuracy: 1e-9)
        XCTAssertEqual(end.longitude, b.longitude, accuracy: 1e-9)
    }

    /// Coincident points have no defined bearing; the maths must not divide
    /// by sin(0).
    func testACoincidentPathDoesNotProduceNaN() {
        let a = point(39.74, -104.99)
        let middle = GreatCircle.interpolate(from: a, to: a, fraction: 0.5)
        XCTAssertEqual(middle.latitude, a.latitude, accuracy: 1e-9)
        XCTAssertFalse(middle.latitude.isNaN)
    }

    // MARK: - Explanations

    /// Every verdict has to say what to do about it. "Blocked" alone tells
    /// the operator nothing they can act on.
    func testEveryVerdictExplainsWhatToDo() {
        let (a, b) = near
        let clear = TerrainProfile.between(
            origin: a, destination: b, originHeight: 10, destinationHeight: 10,
            frequencyHz: 145_050_000,
            sampler: Valley(ridge: 1600, floor: 1300, origin: a, destination: b))
        let blocked = TerrainProfile.between(
            origin: a, destination: b, originHeight: 10, destinationHeight: 10,
            frequencyHz: 145_050_000,
            sampler: Ridge(base: 1600, peak: 2200, origin: a, destination: b,
                           atFraction: 0.5, halfWidthFraction: 0.1))

        // A clear path should point the operator away from terrain as the
        // explanation, which is the genuinely useful part.
        let clearText = clear.verdict.explanation(profile: clear)
        XCTAssertTrue(clearText.lowercased().contains("not what is limiting"), clearText)

        let blockedText = blocked.verdict.explanation(profile: blocked)
        XCTAssertTrue(blockedText.lowercased().contains("digipeater"), blockedText)
        XCTAssertTrue(blockedText.contains("145.050"), blockedText)
    }

    func testTheSummaryIsShortEnoughForABadge() {
        let (a, b) = near
        let profile = TerrainProfile.between(
            origin: a, destination: b, originHeight: 10, destinationHeight: 10,
            frequencyHz: 145_050_000,
            sampler: Valley(ridge: 1600, floor: 1300, origin: a, destination: b))
        XCTAssertLessThan(profile.verdict.summary.count, 40)
    }
}
