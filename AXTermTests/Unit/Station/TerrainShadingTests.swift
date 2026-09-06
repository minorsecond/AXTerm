import XCTest
@testable import AXTerm

/// Turning elevation into pixels.
///
/// Every mistake available here looks plausible on screen: shading lit from
/// the wrong side inverts ridges into valleys, a no-data gap painted as sea
/// level draws a flat plain over unknown ground, and per-tile normalisation
/// makes a flat tile glow like a mountain range. None of them look like bugs.
final class TerrainShadingTests: XCTestCase {

    private let samples = 8

    /// A slope descending toward one compass direction.
    private func slopedGrid(risingToward direction: String) -> [Float] {
        var grid = [Float](repeating: 0, count: samples * samples)
        for row in 0..<samples {
            for column in 0..<samples {
                let height: Float
                switch direction {
                case "north": height = Float(samples - row) * 50
                case "south": height = Float(row) * 50
                case "west": height = Float(samples - column) * 50
                default: height = Float(column) * 50
                }
                grid[row * samples + column] = height
            }
        }
        return grid
    }

    private func shade(_ grid: [Float], row: Int, column: Int) -> Double? {
        TerrainShading.hillshade(grid: grid, samples: samples,
                                 row: row, column: column,
                                 metresPerSampleX: 100, metresPerSampleY: 100)
    }

    // MARK: - Hillshade

    func testFlatGroundShadesUniformly() {
        let flat = [Float](repeating: 1600, count: samples * samples)
        let a = shade(flat, row: 3, column: 3)
        let b = shade(flat, row: 5, column: 4)
        XCTAssertNotNil(a)
        XCTAssertEqual(try XCTUnwrap(a), try XCTUnwrap(b), accuracy: 0.0001)
    }

    /// The whole point of the north-west convention: a slope facing the light
    /// is brighter than one facing away. Get this backwards and every ridge
    /// on the map reads as a valley.
    func testSlopesFacingTheLightAreBrighterThanThoseFacingAway() {
        let facingNorthWest = shade(slopedGrid(risingToward: "south"), row: 4, column: 4)
        let facingSouthEast = shade(slopedGrid(risingToward: "north"), row: 4, column: 4)
        XCTAssertGreaterThan(try XCTUnwrap(facingNorthWest),
                             try XCTUnwrap(facingSouthEast))
    }

    func testEastAndWestFacingSlopesDifferFromEachOther() {
        let east = shade(slopedGrid(risingToward: "west"), row: 4, column: 4)
        let west = shade(slopedGrid(risingToward: "east"), row: 4, column: 4)
        XCTAssertNotEqual(try XCTUnwrap(east), try XCTUnwrap(west), accuracy: 0.01)
    }

    func testShadeStaysWithinRange() {
        for direction in ["north", "south", "east", "west"] {
            let value = try? XCTUnwrap(shade(slopedGrid(risingToward: direction),
                                             row: 4, column: 4))
            XCTAssertGreaterThanOrEqual(value ?? -1, 0)
            XCTAssertLessThanOrEqual(value ?? 2, 1)
        }
    }

    /// A fabricated neighbour produces a fabricated slope, and the edge of a
    /// coverage hole is exactly where it would look like a convincing cliff.
    func testAMissingNeighbourYieldsNoShadeRatherThanAGuess() {
        var grid = slopedGrid(risingToward: "east")
        grid[3 * samples + 3] = Float.nan
        XCTAssertNil(shade(grid, row: 4, column: 4))
    }

    func testTileEdgesAreNotShaded() {
        let grid = slopedGrid(risingToward: "east")
        XCTAssertNil(shade(grid, row: 0, column: 4))
        XCTAssertNil(shade(grid, row: samples - 1, column: 4))
        XCTAssertNil(shade(grid, row: 4, column: 0))
    }

    // MARK: - Pixels

    func testNoDataStaysFullyTransparent() {
        var grid = [Float](repeating: 1600, count: samples * samples)
        grid[2 * samples + 2] = Float.nan
        let pixels = TerrainShading.rgba(from: grid, samples: samples,
                                         style: .elevation,
                                         metresPerSampleX: 100, metresPerSampleY: 100)
        let alpha = pixels[(2 * samples + 2) * 4 + 3]
        XCTAssertEqual(alpha, 0, "a gap must never be painted as ground")
    }

    func testShadingProducesFourBytesPerSample() {
        let grid = slopedGrid(risingToward: "east")
        let pixels = TerrainShading.rgba(from: grid, samples: samples,
                                         style: .hillshade,
                                         metresPerSampleX: 100, metresPerSampleY: 100)
        XCTAssertEqual(pixels.count, samples * samples * 4)
    }

    /// Relief is a shadow, not a coat of paint: flat ground is transparent
    /// and a slope facing away from the light is translucent black.
    ///
    /// An opaque grey tile composited over the map was a whitewash — an
    /// overlay renderer cannot multiply against the basemap, so "flat = white"
    /// lightened everything under it. In dark mode that turned Denver light
    /// grey under MapKit's dark-mode shields and labels.
    func testFlatGroundIsTransparentAndSlopesAreShadow() {
        let flat = [Float](repeating: 1600, count: samples * samples)
        let flatPixels = TerrainShading.rgba(from: flat, samples: samples,
                                             style: .hillshade,
                                             metresPerSampleX: 100, metresPerSampleY: 100)
        XCTAssertEqual(flatPixels[(4 * samples + 4) * 4 + 3], 0, "flat ground changes nothing")

        let away = TerrainShading.rgba(from: slopedGrid(risingToward: "north"), samples: samples,
                                       style: .hillshade,
                                       metresPerSampleX: 100, metresPerSampleY: 100)
        let offset = (4 * samples + 4) * 4
        XCTAssertGreaterThan(away[offset + 3], 0, "a slope facing away from the light casts shadow")
        XCTAssertEqual(away[offset], 0)
        XCTAssertEqual(away[offset + 1], 0)
        XCTAssertEqual(away[offset + 2], 0)

        let toward = TerrainShading.rgba(from: slopedGrid(risingToward: "south"), samples: samples,
                                         style: .hillshade,
                                         metresPerSampleX: 100, metresPerSampleY: 100)
        XCTAssertLessThan(toward[offset + 3], away[offset + 3],
                          "a slope facing the light is lighter than one facing away")
        XCTAssertLessThan(TerrainShading.Style.hillshade.opacity, 1)
    }

    // MARK: - Elevation ramp

    /// Fixed scale, not per-tile. Normalising each tile against its own
    /// extremes puts a seam at every tile boundary and makes a flat tile look
    /// mountainous.
    func testTheRampIsAbsoluteSoTilesAgree() {
        let low = TerrainShading.elevationTint(metres: 1600)
        let sameElsewhere = TerrainShading.elevationTint(metres: 1600)
        XCTAssertEqual(low.0, sameElsewhere.0)
        XCTAssertNotEqual(low.0, TerrainShading.elevationTint(metres: 4000).0)
    }

    func testTheRampRisesToPaleAtAltitude() {
        let lowland = TerrainShading.elevationTint(metres: 0)
        let peak = TerrainShading.elevationTint(metres: 4500)
        XCTAssertGreaterThan(Int(peak.0) + Int(peak.1) + Int(peak.2),
                             Int(lowland.0) + Int(lowland.1) + Int(lowland.2))
    }

    func testValuesOutsideTheRampAreClampedRatherThanWrapped() {
        XCTAssertEqual(TerrainShading.elevationTint(metres: -500).0,
                       TerrainShading.elevationTint(metres: 0).0)
        XCTAssertEqual(TerrainShading.elevationTint(metres: 9000).0,
                       TerrainShading.elevationTint(metres: 4500).0)
    }

    // MARK: - Sample spacing

    /// A degree of longitude is shorter than a degree of latitude everywhere
    /// but the equator; using one for both tilts every slope on the map.
    func testLongitudeSpacingShrinksWithLatitude() {
        let denver = TerrainShading.metresPerSample(tileLatitude: 39, samples: 1024)
        let arctic = TerrainShading.metresPerSample(tileLatitude: 70, samples: 1024)
        XCTAssertLessThan(denver.x, denver.y)
        XCTAssertLessThan(arctic.x, denver.x)
        XCTAssertEqual(arctic.y, denver.y, accuracy: 0.001)
    }

    func testSpacingIsAboutAHundredMetresAtTheStandardResolution() {
        let spacing = TerrainShading.metresPerSample(tileLatitude: 39, samples: 1024)
        XCTAssertEqual(spacing.y, 108.8, accuracy: 2)
    }

    // MARK: - Blending

    /// The fix for terrain burying the map: level ground must multiply to no
    /// change at all. Raw hillshade puts flat terrain at mid-grey, and
    /// multiplying that over the basemap darkened Denver uniformly and hid
    /// the street grid.
    func testFlatGroundReliefIsWhiteSoItMultipliesToNothing() {
        let flat = [Float](repeating: 1600, count: samples * samples)
        let raw = try? XCTUnwrap(shade(flat, row: 4, column: 4))
        XCTAssertEqual(TerrainShading.relief(from: raw ?? 0), 1.0, accuracy: 0.001)
        // And the raw value really is mid-grey, which is what made it a bug.
        XCTAssertLessThan(raw ?? 1, 0.8)
    }

    func testSlopesFacingAwayStillDarken() {
        let facingAway = shade(slopedGrid(risingToward: "north"), row: 4, column: 4)
        XCTAssertLessThan(TerrainShading.relief(from: try XCTUnwrap(facingAway)), 1.0)
    }

    func testReliefNeverBrightens() {
        for direction in ["north", "south", "east", "west"] {
            let value = shade(slopedGrid(risingToward: direction), row: 4, column: 4)
            XCTAssertLessThanOrEqual(
                TerrainShading.relief(from: try XCTUnwrap(value)), 1.0,
                "a multiply layer above 1.0 would brighten the map, not shade it")
        }
    }

    /// Both styles composite normally: an overlay renderer's blend mode never
    /// reaches the basemap, so the shading has to be in the pixels. The
    /// hillshade is still the stronger of the two — it is the subject when
    /// it is on; the elevation tint is background.
    func testEachStyleBlendsInTheWayItsJobNeeds() {
        XCTAssertEqual(TerrainShading.Style.hillshade.blendMode, .normal)
        XCTAssertEqual(TerrainShading.Style.elevation.blendMode, .normal)
        XCTAssertLessThan(TerrainShading.Style.elevation.opacity,
                          TerrainShading.Style.hillshade.opacity)
        for style in TerrainShading.Style.allCases {
            XCTAssertGreaterThan(style.opacity, 0)
            XCTAssertLessThanOrEqual(style.opacity, 1)
        }
    }

    // MARK: - The fast path

    /// The optimisation is only safe if it is the same function. Rather than
    /// trust the algebra that removed four transcendental calls per sample,
    /// check it against the readable version over a wide spread of gradients.
    func testTheFastShadeMatchesTheReadableOne() {
        let light = TerrainShading.LightConstants()
        let gradients = stride(from: -2.0, through: 2.0, by: 0.13)

        for dzdx in gradients {
            for dzdy in gradients {
                let fast = TerrainShading.hillshade(dzdx: dzdx, dzdy: dzdy, light: light)

                // The readable form, inlined here so the reference cannot
                // drift out from under the test.
                let k = TerrainShading.verticalExaggeration
                let slope = atan(k * (dzdx * dzdx + dzdy * dzdy).squareRoot())
                var aspect = atan2(dzdy, -dzdx)
                if aspect < 0 { aspect += 2 * .pi }
                let zenith = (90 - TerrainShading.sunAltitudeDegrees) * .pi / 180
                let azimuth = (360 - TerrainShading.sunAzimuthDegrees + 90) * .pi / 180
                let reference = min(max(
                    cos(zenith) * cos(slope)
                        + sin(zenith) * sin(slope) * cos(azimuth - aspect), 0), 1)

                XCTAssertEqual(fast, reference, accuracy: 1e-9,
                               "dzdx=\(dzdx) dzdy=\(dzdy)")
            }
        }
    }

    /// The degenerate case the algebra has to survive: a zero gradient makes
    /// the aspect undefined, and the fast form must still land on flat.
    func testAZeroGradientGivesTheFlatGroundValue() {
        let light = TerrainShading.LightConstants()
        let shade = TerrainShading.hillshade(dzdx: 0, dzdy: 0, light: light)
        let flat = cos((90 - TerrainShading.sunAltitudeDegrees) * .pi / 180)
        XCTAssertEqual(shade, flat, accuracy: 1e-12)
        XCTAssertEqual(TerrainShading.relief(from: shade), 1.0, accuracy: 1e-12)
    }

    /// The whole-grid path must agree with the per-sample one, since the
    /// render loop inlines the neighbour gathering rather than calling it.
    func testTheRenderedGridAgreesWithPerSampleShading() throws {
        let grid = slopedGrid(risingToward: "east")
        let pixels = TerrainShading.rgba(from: grid, samples: samples,
                                         style: .hillshade,
                                         metresPerSampleX: 100, metresPerSampleY: 100)
        for (row, column) in [(2, 2), (4, 4), (5, 3)] {
            let expected = TerrainShading.relief(
                from: try XCTUnwrap(shade(grid, row: row, column: column)))
            // Relief rides in the alpha channel as shadow: 1 - alpha.
            let actual = 1 - Double(pixels[(row * samples + column) * 4 + 3]) / 255
            XCTAssertEqual(actual, expected, accuracy: 1.0 / 255)
        }
    }

    func testEdgesAndGapsStayTransparentInTheRenderedGrid() {
        var grid = slopedGrid(risingToward: "east")
        grid[4 * samples + 4] = Float.nan
        let pixels = TerrainShading.rgba(from: grid, samples: samples,
                                         style: .hillshade,
                                         metresPerSampleX: 100, metresPerSampleY: 100)
        XCTAssertEqual(pixels[(0 * samples + 3) * 4 + 3], 0, "north edge")
        XCTAssertEqual(pixels[(4 * samples + 4) * 4 + 3], 0, "the gap itself")
        XCTAssertEqual(pixels[(4 * samples + 5) * 4 + 3], 0, "neighbour of a gap")
    }

    /// Guards the thing the operator actually noticed: a full tile taking
    /// seconds. Generous enough not to be flaky on a loaded machine, tight
    /// enough that reintroducing per-sample trigonometry would trip it.
    func testAFullTileShadesQuickly() throws {
        let side = ElevationStore.tileSamples
        var grid = [Float](repeating: 0, count: side * side)
        for row in 0..<side {
            for column in 0..<side {
                grid[row * side + column] =
                    Float(1600 + sin(Double(row) / 40) * 300 + cos(Double(column) / 55) * 200)
            }
        }
        let spacing = TerrainShading.metresPerSample(tileLatitude: 39, samples: side)

        let started = Date()
        let pixels = TerrainShading.rgba(from: grid, samples: side, style: .hillshade,
                                         metresPerSampleX: spacing.x,
                                         metresPerSampleY: spacing.y)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(pixels.count, side * side * 4)
        XCTAssertLessThan(elapsed, 0.5,
                          "a tile took \(String(format: "%.3f", elapsed))s to shade")
    }
}
