import XCTest
import CoreLocation
@testable import AXTerm

/// The message that carries a map layer over the air.
///
/// Mostly about the coordinate system. A recipient who plots a zone on the
/// wrong datum gets an answer that looks entirely reasonable and is in the
/// wrong place, so the CRS is asserted here rather than left to a code review.
final class MapOverlayMessageTests: XCTestCase {

    private let generated = Date(timeIntervalSince1970: 1_700_000_000)

    private func layer(_ features: [MapOverlayFeature], name: String = "Evac Zones")
        -> MapOverlayLayer {
        MapOverlayLayer(id: "x.geojson", name: name, features: features, colorName: "blue")
    }

    private func mark(_ name: String, _ lat: Double, _ lon: Double) -> MapOverlayFeature {
        MapOverlayFeature(name: name,
                          geometry: .point(CLLocationCoordinate2D(latitude: lat, longitude: lon)))
    }

    private func draft(_ layer: MapOverlayLayer,
                       format: MapOverlayExport.Format = .geoJSON) -> MapOverlayMessage.Draft {
        MapOverlayMessage.draft(
            layer: layer, format: format, attachment: Data(repeating: 0, count: 2048),
            assessment: MapOverlayExport.assess(
                byteCount: 2048,
                airtime: WinlinkAirtimeEstimate.forGateway(
                    callsign: "W0ARP-10", frequencyHz: nil, quality: [:])),
            operatorCallsign: "k0epi", generatedAt: generated)
    }

    // MARK: - Coordinate system

    /// Stated in the body every time, in both formats. This is the difference
    /// between the recipient plotting a zone in Colorado and plotting it in
    /// the Gulf of Guinea.
    func testTheCoordinateSystemIsAlwaysStated() {
        for format in MapOverlayExport.Format.allCases {
            let body = draft(layer([mark("Camp", 39.74, -104.99)]), format: format).body
            XCTAssertTrue(body.contains("WGS 84"), "\(format): \(body)")
            XCTAssertTrue(body.contains("EPSG:4326"), "\(format)")
        }
    }

    /// GeoJSON has no projection sidecar, so the body carries the WKT — a
    /// recipient whose software wants a `.prj` can paste it and be certain
    /// rather than assuming.
    func testGeoJSONCarriesTheProjectionWKT() {
        let body = draft(layer([mark("Camp", 39.74, -104.99)]), format: .geoJSON).body
        XCTAssertTrue(body.contains("GEOGCS"), body)
        XCTAssertTrue(body.contains(ShapefileWriter.wgs84WKT))
        // And the reader accepts exactly what is quoted, so following the
        // instruction actually works.
        XCTAssertNoThrow(try ShapefileReader.validateProjection(ShapefileWriter.wgs84WKT))
    }

    /// Coordinate order is the other half of getting this right, and is the
    /// opposite of the shapefile convention — worth saying out loud.
    func testGeoJSONStatesCoordinateOrder() {
        let body = draft(layer([mark("Camp", 39.74, -104.99)]), format: .geoJSON).body
        XCTAssertTrue(body.contains("[longitude, latitude]"), body)
    }

    /// For a shapefile the `.prj` is in the archive and is authoritative, so
    /// the body points at it rather than repeating a WKT that could disagree.
    func testShapefilePointsAtItsOwnPRJ() {
        let body = draft(layer([mark("Camp", 39.74, -104.99)]), format: .shapefile).body
        XCTAssertTrue(body.contains(".prj"), body)
        XCTAssertTrue(body.lowercased().contains("authoritative"), body)
    }

    // MARK: - Contents

    /// The most important case — a handful of marked positions — must be
    /// readable even if the attachment is stripped, truncated, or opened on
    /// something with no mapping software at all.
    func testMarkPositionsAppearInTheBody() {
        let body = draft(layer([mark("Staging", 39.74, -104.99)])).body
        XCTAssertTrue(body.contains("Staging"), body)
        // Degrees-decimal-minutes, as the Winlink position templates use.
        XCTAssertTrue(body.contains("39-44.40N"), body)
        XCTAssertTrue(body.contains("104-59.40W"), body)
    }

    /// Truncation is disclosed. The recipient must be able to tell a short
    /// list from a shortened one.
    func testALongListSaysHowMuchWasLeftOut() {
        let many = (0..<50).map { mark("Point \($0)", 39 + Double($0) / 100, -105) }
        let body = draft(layer(many)).body

        XCTAssertTrue(body.contains("Point 0"))
        XCTAssertFalse(body.contains("Point 49"))
        XCTAssertTrue(body.contains("\(50 - MapOverlayMessage.listedFeatureLimit) more in the attachment"),
                      body)
    }

    func testFeatureCountsAreSummarised() {
        let mixed = layer([
            mark("A", 39, -105),
            MapOverlayFeature(name: "Route", geometry: .polyline([[
                CLLocationCoordinate2D(latitude: 39, longitude: -105),
                CLLocationCoordinate2D(latitude: 40, longitude: -104),
            ]])),
        ])
        XCTAssertEqual(MapOverlayMessage.featureSummary(mixed), "1 mark, 1 line")
        XCTAssertEqual(MapOverlayMessage.featureSummary(layer([])), "none")
    }

    // MARK: - Envelope

    func testTheDraftNamesTheLayerAndItsFile() {
        let result = draft(layer([mark("Camp", 39, -105)], name: "Evac Zones"))
        XCTAssertEqual(result.subject, "Map layer: Evac Zones")
        XCTAssertEqual(result.attachmentName, "Evac_Zones.geojson")
    }

    /// The body is a B2F message body, which is CRLF throughout.
    func testTheBodyUsesCRLFLineEndings() {
        let body = draft(layer([mark("Camp", 39, -105)])).body
        XCTAssertTrue(body.contains("\r\n"))
        XCTAssertFalse(body.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testTimestampsAreUTC() {
        XCTAssertEqual(MapOverlayMessage.timestamp(generated), "2023/11/14 22:13 UTC")
    }

    func testTheOperatorCallsignIsUpperCased() {
        XCTAssertTrue(draft(layer([mark("Camp", 39, -105)])).body.contains("K0EPI"))
    }
}

/// Deciding whether a layer is reasonable to put on the air at all.
final class MapOverlayExportTests: XCTestCase {

    /// Measured rate for this station on 145.050, from its own session log.
    private var slowLink: WinlinkAirtimeEstimate {
        WinlinkAirtimeEstimate.forGateway(callsign: "", frequencyHz: nil, quality: [:])
    }

    /// A dozen marks is the case worth supporting: a couple of kilobytes,
    /// under a minute, one session.
    func testAHandfulOfMarksIsPractical() {
        let assessment = MapOverlayExport.assess(byteCount: 2_048, airtime: slowLink)
        XCTAssertFalse(assessment.isImpractical)
        XCTAssertEqual(assessment.sessionsRequired, 1)
    }

    /// A county boundary is not. Saying so plainly is the point — the app
    /// must not present thirteen hours of airtime as a normal thing to do.
    func testACountyBoundaryIsCalledImpractical() {
        let assessment = MapOverlayExport.assess(byteCount: 1_500_000, airtime: slowLink)
        XCTAssertTrue(assessment.isImpractical)
        XCTAssertTrue(assessment.advice.lowercased().contains("not a reasonable"), assessment.advice)
        // And it offers the alternative rather than only refusing.
        XCTAssertTrue(assessment.advice.lowercased().contains("memory card"), assessment.advice)
    }

    /// Over the air the answer is always GeoJSON: it is text, so LZHUF
    /// compresses it, where a zipped shapefile is already compressed.
    func testGeoJSONIsRecommendedForTheRadio() {
        XCTAssertEqual(MapOverlayExport.recommendedFormat(forRadio: true), .geoJSON)
        XCTAssertEqual(MapOverlayExport.recommendedFormat(forRadio: false), .shapefile)
    }

    func testEveryFormatExplainsItself() {
        for format in MapOverlayExport.Format.allCases {
            XCTAssertFalse(format.summary.isEmpty, format.rawValue)
            XCTAssertFalse(format.displayName.isEmpty, format.rawValue)
        }
    }
}
