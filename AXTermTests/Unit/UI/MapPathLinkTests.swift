//
//  MapPathLinkTests.swift
//  AXTermTests
//

import XCTest
import MapKit
@testable import AXTerm

final class MapPathLinkTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let denver = GreatCircle.Point(latitude: 39.74, longitude: -104.99)
    private let boulder = GreatCircle.Point(latitude: 40.015, longitude: -105.27)

    private func path(_ from: String, _ to: String, via: [String] = [],
                      evidence: NetworkPath.Evidence = .heardDirect,
                      unanswered: Int = 0) -> NetworkPath {
        NetworkPath(from: from, to: to, via: via, evidence: evidence,
                    observations: 1, firstSeen: t0, lastSeen: t0,
                    unansweredAttempts: unanswered)
    }

    func testALinkIsDrawnWhenBothEndsArePlaced() {
        let links = MapPathLink.links(
            from: [path("K0EPI-7", "W0ARP-10")],
            positions: ["K0EPI-7": denver, "W0ARP-10": boulder])
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.evidence, .heardDirect)
    }

    func testAnUnplacedEndDropsTheLink() {
        // A line to a station whose position is unknown would be a drawing of
        // an assumption.
        let links = MapPathLink.links(
            from: [path("K0EPI-7", "N0WHERE")],
            positions: ["K0EPI-7": denver])
        XCTAssertTrue(links.isEmpty)
    }

    func testTwoSSIDsAtOneCoordinateDrawNothing() {
        // K0NTS-1 and K0NTS-10 resolve through the same licence record, so a
        // link between them would be a dot rather than a line.
        let links = MapPathLink.links(
            from: [path("K0NTS-1", "K0NTS-10")],
            positions: ["K0NTS-1": denver, "K0NTS-10": denver])
        XCTAssertTrue(links.isEmpty)
    }

    func testThePolylineFollowsAGreatCircle() {
        let link = try? XCTUnwrap(MapPathLink.links(
            from: [path("K0EPI-7", "W0ARP-10")],
            positions: ["K0EPI-7": denver, "W0ARP-10": boulder]).first)
        // Sampled rather than a straight segment, so the drawn line and the
        // terrain profile agree about which ridge is in the way.
        XCTAssertGreaterThan(link?.polyline.pointCount ?? 0, 2)
    }

    func testTheLabelNamesBothEndsAndTheHops() {
        let link = try? XCTUnwrap(MapPathLink.links(
            from: [path("KB5YZB-7", "K0NTS-1", via: ["DRLNOD"], evidence: .heardDigipeated)],
            positions: ["KB5YZB-7": denver, "K0NTS-1": boulder]).first)
        XCTAssertTrue(link?.label.contains("DRLNOD") ?? false)
        XCTAssertTrue(link?.label.contains("Digipeated") ?? false)
    }

    func testADirectPathSaysSoInItsLabel() {
        let link = try? XCTUnwrap(MapPathLink.links(
            from: [path("K0EPI-7", "W0ARP-10")],
            positions: ["K0EPI-7": denver, "W0ARP-10": boulder]).first)
        XCTAssertTrue(link?.label.contains("direct") ?? false)
    }

    func testSuspectPathsCarryTheFlagThroughToDrawing() {
        let suspect = path("K0NTS-1", "KF0BPN-1", unanswered: 4)
        let link = try? XCTUnwrap(MapPathLink.links(
            from: [suspect],
            positions: ["K0NTS-1": denver, "KF0BPN-1": boulder]).first)
        XCTAssertTrue(link?.isSuspect ?? false)
    }

    // MARK: - Colour is the legend

    func testEvidenceLevelsAreVisuallyDistinct() {
        let positions = ["A": denver, "B": boulder]
        let colours = NetworkPath.Evidence.allCases.compactMap { evidence -> String? in
            guard let link = MapPathLink.links(
                from: [path("A", "B", evidence: evidence)],
                positions: positions).first else { return nil }
            return OfflineBasemapMapView.linkColor(for: link).description
        }
        // A map whose colours repeat cannot be read without the legend.
        XCTAssertEqual(Set(colours).count, NetworkPath.Evidence.allCases.count)
    }

    func testASuspectPathOverridesItsEvidenceColour() {
        let positions = ["A": denver, "B": boulder]
        let normal = try? XCTUnwrap(MapPathLink.links(
            from: [path("A", "B", evidence: .heardDirect)], positions: positions).first)
        let suspect = try? XCTUnwrap(MapPathLink.links(
            from: [path("A", "B", evidence: .heardDirect, unanswered: 4)],
            positions: positions).first)
        XCTAssertNotEqual(
            OfflineBasemapMapView.linkColor(for: normal!).description,
            OfflineBasemapMapView.linkColor(for: suspect!).description)
    }

    // MARK: - Terrain forecasts

    private func prediction(_ from: String, _ to: String,
                            outlook: PredictedPath.Outlook,
                            assumed: Bool = true) -> PredictedPath {
        PredictedPath(from: from, to: to, outlook: outlook,
                      distanceKilometres: 37.4, assumedHeights: assumed)
    }

    func testAWorkableForecastIsDrawnAndMarkedAsAForecast() {
        let links = MapPathLink.links(
            fromPredictions: [prediction("A", "B",
                                         outlook: .marginal(worstFresnelRatio: 0.3))],
            positions: ["A": denver, "B": boulder])
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(links.first?.isPrediction == true)
        // Weakest evidence on purpose: nothing has travelled it.
        XCTAssertEqual(links.first?.evidence, .transitive)
        XCTAssertFalse(links.first?.isSuspect == true)
    }

    /// Every blocked pair on a busy map is a mesh of lines saying "no".
    func testBlockedForecastsAreNotDrawn() {
        let links = MapPathLink.links(
            fromPredictions: [prediction("A", "B",
                                         outlook: .blocked(byMetres: 40, atMetres: 8000))],
            positions: ["A": denver, "B": boulder])
        XCTAssertTrue(links.isEmpty)
    }

    func testAnUnplacedEndDropsTheForecast() {
        let links = MapPathLink.links(
            fromPredictions: [prediction("A", "B",
                                         outlook: .promising(worstFresnelRatio: 0.8))],
            positions: ["A": denver])
        XCTAssertTrue(links.isEmpty)
    }

    func testTheLabelCarriesDistanceOutlookAndTheHeightCaveat() {
        let label = MapPathLink.links(
            fromPredictions: [prediction("K0EPI-7", "W0ARP-10",
                                         outlook: .marginal(worstFresnelRatio: 0.3))],
            positions: ["K0EPI-7": denver, "W0ARP-10": boulder]).first?.label ?? ""
        XCTAssertTrue(label.contains("K0EPI-7"))
        XCTAssertTrue(label.contains("W0ARP-10"))
        XCTAssertTrue(label.contains("37 km"))
        XCTAssertTrue(label.contains("Marginal"))
        XCTAssertTrue(label.contains("assumed height"))
    }

    /// A forecast built on two recorded heights is a better claim than one
    /// built on the default, and must not carry the same caveat.
    func testARecordedHeightDropsTheCaveatFromTheLabel() {
        let label = MapPathLink.links(
            fromPredictions: [prediction("A", "B",
                                         outlook: .promising(worstFresnelRatio: 0.9),
                                         assumed: false)],
            positions: ["A": denver, "B": boulder]).first?.label ?? ""
        XCTAssertFalse(label.contains("assumed height"))
    }

    /// A forecast must never borrow a colour that means a measurement.
    func testForecastColourIsDistinctFromEveryEvidenceColour() {
        let positions = ["A": denver, "B": boulder]
        var colours = Set(NetworkPath.Evidence.allCases.compactMap { evidence -> String? in
            MapPathLink.links(from: [path("A", "B", evidence: evidence)],
                              positions: positions).first
                .map { OfflineBasemapMapView.linkColor(for: $0).description }
        })
        // The suspect colour is a measurement too — a path that was tried.
        if let suspect = MapPathLink.links(
            from: [path("A", "B", evidence: .heardDirect, unanswered: 4)],
            positions: positions).first {
            colours.insert(OfflineBasemapMapView.linkColor(for: suspect).description)
        }

        let forecast = MapPathLink.links(
            fromPredictions: [prediction("A", "B",
                                         outlook: .marginal(worstFresnelRatio: 0.3))],
            positions: positions).first
        let forecastColour = OfflineBasemapMapView
            .linkColor(for: try! XCTUnwrap(forecast)).description
        XCTAssertFalse(colours.contains(forecastColour))
    }
}
