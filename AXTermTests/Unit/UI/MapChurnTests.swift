import XCTest
@testable import AXTerm

/// Does the map ask for the same picture twice?
///
/// The map's update pass turns derived data into MapKit mutations, and every
/// mutation — an annotation added, an overlay replaced — makes MapKit
/// re-resolve its label layer. So the property that matters is not what the
/// map draws but what it *changes*: given inputs that have not meaningfully
/// changed, the derivation must produce byte-identical output, or the map
/// churns.
///
/// These are the tests that were missing. Every round of the 2026-09-01
/// "the points jump" investigation was a live build and a pasted log,
/// because the reconciler's decisions were only observable through a running
/// MKMapView. They are pure functions over data and they belong here.
final class MapChurnTests: XCTestCase {

    private let observer = GreatCircle.Point(latitude: 39.6, longitude: -104.7)

    private func point(kmNorth: Double, kmEast: Double = 0) -> GreatCircle.Point {
        GreatCircle.Point(latitude: observer.latitude + kmNorth / 111.32,
                          longitude: observer.longitude + kmEast / 111.32)
    }

    private func path(_ from: String, _ to: String,
                      via: [String] = [],
                      evidence: NetworkPath.Evidence = .heardDirect,
                      unanswered: Int = 0) -> NetworkPath {
        NetworkPath(from: from, to: to, via: via, evidence: evidence,
                    observations: 1, firstSeen: Date(timeIntervalSince1970: 1_000),
                    lastSeen: Date(timeIntervalSince1970: 2_000),
                    unansweredAttempts: unanswered)
    }

    private var positions: [String: GreatCircle.Point] {
        ["K0EPI-7": observer,
         "W0ARP-10": point(kmNorth: 30),
         "KB5YZB-7": point(kmNorth: 10, kmEast: 20),
         "AB0VZ": point(kmNorth: -15, kmEast: 5)]
    }

    // MARK: - Links

    /// Re-deriving from unchanged inputs must give the same lines in the same
    /// places. A line whose geometry signature differs is a line the map
    /// tears out and re-adds.
    func testLinkGeometryIsIdenticalWhenNothingChanged() {
        let paths = [path("K0EPI-7", "W0ARP-10"),
                     path("K0EPI-7", "KB5YZB-7"),
                     path("AB0VZ", "K0EPI-7")]

        let first = MapPathLink.links(from: paths, positions: positions)
        let second = MapPathLink.links(from: paths, positions: positions)

        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(
            first.map(OfflineBasemapMapView.linkGeometrySignature).sorted(),
            second.map(OfflineBasemapMapView.linkGeometrySignature).sorted())
    }

    /// The fix this file was written for: a path being proven is the same
    /// line in a different colour. Replacing the overlay for that ripples
    /// MapKit's labels, and evidence improves constantly on a live channel.
    func testProvingAPathChangesItsStyleButNotItsGeometry() throws {
        let before = MapPathLink.links(
            from: [path("K0EPI-7", "W0ARP-10", evidence: .heardDirect)],
            positions: positions)
        let after = MapPathLink.links(
            from: [path("K0EPI-7", "W0ARP-10", evidence: .sessionEstablished)],
            positions: positions)

        let one = try XCTUnwrap(before.first)
        let other = try XCTUnwrap(after.first)
        XCTAssertEqual(one.id, other.id)
        XCTAssertEqual(OfflineBasemapMapView.linkGeometrySignature(one),
                       OfflineBasemapMapView.linkGeometrySignature(other),
                       "the stations did not move, so the line must not be replaced")
        XCTAssertNotEqual(OfflineBasemapMapView.linkStyleSignature(one),
                          OfflineBasemapMapView.linkStyleSignature(other),
                          "but it must repaint, or a proven path keeps the unproven colour")
    }

    /// A path going from plausible to suspect is likewise a repaint.
    func testAPathTurningSuspectIsARepaintNotARebuild() throws {
        let before = MapPathLink.links(
            from: [path("K0EPI-7", "AB0VZ", unanswered: 0)], positions: positions)
        let after = MapPathLink.links(
            from: [path("K0EPI-7", "AB0VZ", unanswered: 5)], positions: positions)

        let one = try XCTUnwrap(before.first)
        let other = try XCTUnwrap(after.first)
        XCTAssertEqual(OfflineBasemapMapView.linkGeometrySignature(one),
                       OfflineBasemapMapView.linkGeometrySignature(other))
        XCTAssertNotEqual(OfflineBasemapMapView.linkStyleSignature(one),
                          OfflineBasemapMapView.linkStyleSignature(other))
    }

    /// A station that actually moves must move its lines — the repaint path
    /// must not swallow a real change.
    func testAStationMovingDoesChangeTheGeometry() throws {
        let paths = [path("K0EPI-7", "W0ARP-10")]
        var moved = positions
        moved["W0ARP-10"] = point(kmNorth: 45)

        let one = try XCTUnwrap(MapPathLink.links(from: paths, positions: positions).first)
        let other = try XCTUnwrap(MapPathLink.links(from: paths, positions: moved).first)
        XCTAssertNotEqual(OfflineBasemapMapView.linkGeometrySignature(one),
                          OfflineBasemapMapView.linkGeometrySignature(other))
    }

    // MARK: - Annotations

    /// The flapping bug, as a test rather than a log line.
    ///
    /// An alias sits in the via-path layer or the directory layer depending
    /// on whether traffic has lately used it, and traffic moves it between
    /// them constantly. Which layer holds it must not decide whether it is
    /// on the map, or it appears and disappears with the packets — which is
    /// exactly what the field log showed, fifteen BBS aliases at a time.
    func testAnAliasIsDrawnRegardlessOfWhichLayerHoldsIt() throws {
        let aliases = NodeAliasDirectory(entries: [
            "HNTBBS": NodeAliasDirectory.Entry(
                alias: "HNTBBS", callsign: "W0HNT-1", service: "B",
                heardAt: Date(timeIntervalSince1970: 1_000), announcements: 1)
        ])
        // No operator record anywhere, so the only thing that can place this
        // alias is the locator its own callsign beaconed.
        let announced = ["W0HNT-1": "DM79po"]
        let heard = [station("K0NTS-1")]

        // The directory layer: the alias is not in any via path.
        let directoryLayer = HeardStationMap.directoryNodeEntries(
            aliases: aliases, alreadyShown: [], shownCallsigns: [],
            directory: [:], announcedGrids: announced,
            stations: heard, excluding: "K0EPI-7")

        // The via-path layer: traffic has just routed through it, so
        // `coreEntries` owns it and the directory layer is excluding it.
        let coreLayer = HeardStationMap.aliasEntries(
            aliases: aliases, usedAliases: ["HNTBBS"],
            directory: [:], stations: heard)
            .map {
                HeardStationMap.placingFromAnnouncedGrid(
                    $0, aliases: aliases, announcedGrids: announced)
            }

        let fromDirectory = try XCTUnwrap(
            directoryLayer.first { $0.callsign == "HNTBBS" },
            "the directory layer must place it")
        let fromCore = try XCTUnwrap(
            coreLayer.first { $0.callsign == "HNTBBS" })

        XCTAssertTrue(fromDirectory.isPlaced)
        XCTAssertTrue(fromCore.isPlaced,
                      "an alias traffic just routed through must not vanish")
        XCTAssertEqual(fromDirectory.position?.latitude, fromCore.position?.latitude)
        XCTAssertEqual(fromDirectory.position?.longitude, fromCore.position?.longitude)
    }

    /// The whole placement pipeline, re-derived: same stations in, same
    /// marker ids and coordinates out. A difference here is an annotation
    /// the map adds or removes for nothing.
    func testTheMarkerSetIsIdenticalWhenReDerivedFromTheSameStations() {
        let stations = [
            station("K0NTS-1"), station("W0ARP-10"),
            station("N3HYM-15"), station("AB0VZ")
        ]
        let grids = ["K0NTS-1": "DM79gr", "W0ARP-10": "DM79ql",
                     "N3HYM-15": "DM79po", "AB0VZ": "DM78ab"]

        func derive() -> [String: GreatCircle.Point] {
            let entries = HeardStationMap.entries(
                stations: stations, directory: [:], gatewayGrids: grids,
                excluding: "K0EPI-7")
            return HeardStationMap.fannedPositions(entries)
        }

        let first = derive()
        let second = derive()
        XCTAssertEqual(first.keys.sorted(), second.keys.sorted())
        for call in first.keys {
            XCTAssertEqual(first[call]?.latitude, second[call]?.latitude, "\(call)")
            XCTAssertEqual(first[call]?.longitude, second[call]?.longitude, "\(call)")
        }
    }

    /// Hearing an existing station again must not disturb anyone's marker.
    /// This is the common case by far — one packet a second — so any churn
    /// here is churn all the time.
    func testHearingAnExistingStationAgainMovesNothing() {
        let grids = ["K0NTS-1": "DM79gr", "W0ARP-10": "DM79ql", "N3HYM-15": "DM79po"]
        let before = [station("K0NTS-1", heard: 10),
                      station("W0ARP-10", heard: 5),
                      station("N3HYM-15", heard: 1)]
        let after = [station("K0NTS-1", heard: 11),   // one more packet
                     station("W0ARP-10", heard: 5),
                     station("N3HYM-15", heard: 1)]

        func places(_ stations: [Station]) -> [String: GreatCircle.Point] {
            HeardStationMap.fannedPositions(
                HeardStationMap.entries(stations: stations, directory: [:],
                                        gatewayGrids: grids, excluding: "K0EPI-7"))
        }

        let one = places(before)
        let other = places(after)
        XCTAssertEqual(one.keys.sorted(), other.keys.sorted(),
                       "no marker may appear or disappear because a packet arrived")
        for call in one.keys {
            XCTAssertEqual(one[call]?.latitude, other[call]?.latitude, "\(call) moved")
            XCTAssertEqual(one[call]?.longitude, other[call]?.longitude, "\(call) moved")
        }
    }

    private func station(_ call: String, heard: Int = 1) -> Station {
        Station(call: call, lastHeard: Date(timeIntervalSince1970: 2_000),
                heardCount: heard, lastVia: [])
    }
}
