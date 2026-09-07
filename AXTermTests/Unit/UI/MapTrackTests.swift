//
//  MapTrackTests.swift
//  AXTermTests
//

import XCTest
import MapKit
@testable import AXTerm

final class MapTrackTests: XCTestCase {

    private let a = GreatCircle.Point(latitude: 39.7392, longitude: -104.9903)
    private let b = GreatCircle.Point(latitude: 39.7500, longitude: -104.9800)
    private let c = GreatCircle.Point(latitude: 39.7600, longitude: -104.9700)

    func testPolylineHasOnePointPerFix() {
        let track = MapTrack(id: "W0OOD-9", points: [a, b, c])
        XCTAssertEqual(track.polyline.pointCount, 3)
    }

    func testGeometrySignatureChangesWhenAFixIsAppended() {
        let two = MapTrack(id: "W0OOD-9", points: [a, b])
        let three = MapTrack(id: "W0OOD-9", points: [a, b, c])
        XCTAssertNotEqual(two.geometrySignature, three.geometrySignature,
                          "a new fix must rebuild the trail")
    }

    func testGeometrySignatureIsStableForTheSamePath() {
        // A trail that has not moved must not be rebuilt — the map keys its
        // batched overlay diff on this being identical across passes.
        let first = MapTrack(id: "W0OOD-9", points: [a, b, c])
        let second = MapTrack(id: "W0OOD-9", points: [a, b, c])
        XCTAssertEqual(first.geometrySignature, second.geometrySignature)
    }

    func testGeometrySignatureIgnoresSubMetreDrift() {
        // Rounded to five decimals (~1 m), so floating-point noise in a
        // re-derived fix cannot pass for a move and churn the overlay.
        let jittered = GreatCircle.Point(latitude: a.latitude + 1e-7,
                                         longitude: a.longitude - 1e-7)
        let steady = MapTrack(id: "X", points: [a, b])
        let noisy = MapTrack(id: "X", points: [jittered, b])
        XCTAssertEqual(steady.geometrySignature, noisy.geometrySignature)
    }

    func testSymbolEquatability() {
        XCTAssertEqual(APRSMapSymbol(table: "/", code: ">"),
                       APRSMapSymbol(table: "/", code: ">"))
        XCTAssertNotEqual(APRSMapSymbol(table: "/", code: ">"),
                          APRSMapSymbol(table: "/", code: "#"))
    }
}
