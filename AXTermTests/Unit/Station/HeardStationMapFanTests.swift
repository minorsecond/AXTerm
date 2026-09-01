import XCTest
@testable import AXTerm

/// Where a fanned marker lands must depend on the stations, not on the order
/// they happened to arrive in.
final class HeardStationMapFanTests: XCTestCase {

    /// Two stations a few centimetres apart round to the same cluster key but
    /// are not the same point, so whichever one the cluster listed first
    /// became the centre everything else fanned around — and the map rebuilds
    /// that list as packets arrive.
    func testFanningDoesNotDependOnInputOrder() throws {
        let a = entry("K0EPI-1", latitude: 39.600001, longitude: -104.700001)
        let b = entry("K0EPI-7", latitude: 39.600002, longitude: -104.700002)

        let forwards = HeardStationMap.fannedPositions([a, b])
        let backwards = HeardStationMap.fannedPositions([b, a])

        XCTAssertEqual(forwards.keys.sorted(), backwards.keys.sorted())
        for callsign in forwards.keys {
            let one = try XCTUnwrap(forwards[callsign])
            let other = try XCTUnwrap(backwards[callsign])
            XCTAssertEqual(one.latitude, other.latitude, accuracy: 1e-12,
                           "\(callsign) latitude moved")
            XCTAssertEqual(one.longitude, other.longitude, accuracy: 1e-12,
                           "\(callsign) longitude moved")
        }
    }

    /// A station on its own sits exactly where it is; only a crowd is fanned.
    func testALoneStationIsNotMoved() throws {
        let placed = HeardStationMap.fannedPositions(
            [entry("K0EPI-7", latitude: 39.6, longitude: -104.7)])
        let point = try XCTUnwrap(placed["K0EPI-7"])
        XCTAssertEqual(point.latitude, 39.6, accuracy: 1e-12)
        XCTAssertEqual(point.longitude, -104.7, accuracy: 1e-12)
    }

    /// The jitter. Spacing markers evenly meant `2pi * index / count`, so a
    /// station arriving in the same grid square changed both terms for
    /// everyone already there and shifted every one of them by up to the fan
    /// radius. The map recomputes as packets arrive, so on a busy channel
    /// this happened constantly.
    func testAStationDoesNotMoveWhenOthersJoinItsCluster() throws {
        let a = entry("K0EPI-1", latitude: 39.6, longitude: -104.7)
        let b = entry("K0EPI-7", latitude: 39.6, longitude: -104.7)
        let c = entry("W0ARP-10", latitude: 39.6, longitude: -104.7)
        let d = entry("N3HYM-15", latitude: 39.6, longitude: -104.7)

        let pair = HeardStationMap.fannedPositions([a, b])
        let trio = HeardStationMap.fannedPositions([a, b, c])
        let quartet = HeardStationMap.fannedPositions([a, b, c, d])

        for callsign in ["K0EPI-1", "K0EPI-7"] {
            let two = try XCTUnwrap(pair[callsign])
            let three = try XCTUnwrap(trio[callsign])
            let four = try XCTUnwrap(quartet[callsign])
            XCTAssertEqual(two.latitude, three.latitude, accuracy: 1e-12,
                           "\(callsign) moved when a third station was heard")
            XCTAssertEqual(two.longitude, three.longitude, accuracy: 1e-12,
                           "\(callsign) moved when a third station was heard")
            XCTAssertEqual(three.latitude, four.latitude, accuracy: 1e-12,
                           "\(callsign) moved when a fourth station was heard")
            XCTAssertEqual(three.longitude, four.longitude, accuracy: 1e-12,
                           "\(callsign) moved when a fourth station was heard")
        }
    }

    /// A station leaving the square must not shift the ones that remain.
    ///
    /// The departing station sorts *before* the one being checked, so under
    /// even spacing its removal shifted every later index down one and swung
    /// the survivors around the circle.
    func testAStationDoesNotMoveWhenAnotherLeavesItsCluster() throws {
        let gone = entry("AB0VZ", latitude: 39.6, longitude: -104.7)
        let kept = entry("K0EPI-7", latitude: 39.6, longitude: -104.7)
        let other = entry("W0ARP-10", latitude: 39.6, longitude: -104.7)

        let before = HeardStationMap.fannedPositions([gone, kept, other])
        let after = HeardStationMap.fannedPositions([kept, other])

        let was = try XCTUnwrap(before["K0EPI-7"])
        let now = try XCTUnwrap(after["K0EPI-7"])
        XCTAssertEqual(was.latitude, now.latitude, accuracy: 1e-12,
                       "K0EPI-7 swung round when AB0VZ dropped out")
        XCTAssertEqual(was.longitude, now.longitude, accuracy: 1e-12,
                       "K0EPI-7 swung round when AB0VZ dropped out")
    }

    /// Members of a cluster differ by a fraction of a metre, so the centre
    /// cannot be any one of their raw positions or it moves with the
    /// membership. All three coordinates below round to one cluster key —
    /// they have to, or they would not be a cluster — but they are not the
    /// same point, and the alphabetically-first of them differs between the
    /// two sets.
    func testTheCentreDoesNotFollowWhoeverIsInTheCluster() throws {
        let ab = entry("AB0VZ", latitude: 39.6000010, longitude: -104.7000010)
        let k0 = entry("K0EPI-7", latitude: 39.6000023, longitude: -104.7000023)
        let w0 = entry("W0ARP-10", latitude: 39.6000041, longitude: -104.7000041)

        let ledByAB = HeardStationMap.fannedPositions([ab, k0])
        let ledByK0 = HeardStationMap.fannedPositions([k0, w0])

        let one = try XCTUnwrap(ledByAB["K0EPI-7"])
        let other = try XCTUnwrap(ledByK0["K0EPI-7"])
        XCTAssertEqual(one.latitude, other.latitude, accuracy: 1e-12,
                       "the centre followed whichever member sorted first")
        XCTAssertEqual(one.longitude, other.longitude, accuracy: 1e-12,
                       "the centre followed whichever member sorted first")
    }

    /// Swift's `hashValue` is seeded per process. Placing markers with it
    /// would move every one of them on relaunch, which is the same bug on a
    /// slower clock — so the hash has to be one we own and pin.
    func testTheHashIsFixedRatherThanSeededPerProcess() {
        // FNV-1a is fully specified; these are its published vectors, not
        // values observed from this implementation.
        XCTAssertEqual(HeardStationMap.stableHash(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(HeardStationMap.stableHash("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(HeardStationMap.stableHash("foobar"), 0x85944171f73967e8)
    }

    /// Stations sharing a point must still end up somewhere distinct, or the
    /// fan has stopped doing its job.
    func testCoLocatedStationsStillSeparate() throws {
        let calls = ["K0EPI-1", "K0EPI-7", "W0ARP-10", "N3HYM-15", "DRLNOD", "AB0VZ"]
        let placed = HeardStationMap.fannedPositions(
            calls.map { entry($0, latitude: 39.6, longitude: -104.7) })
        XCTAssertEqual(placed.count, calls.count)
        for (i, one) in calls.enumerated() {
            for other in calls[(i + 1)...] {
                let p = try XCTUnwrap(placed[one])
                let q = try XCTUnwrap(placed[other])
                let metres = GreatCircle.kilometres(from: p, to: q) * 1000
                XCTAssertGreaterThan(metres, 20,
                                     "\(one) and \(other) landed on top of each other")
            }
        }
    }

    /// The DRLNOD crash, 2026-09-01: a node that transmits its own beacons
    /// is a heard station, and one that also relays traffic appears as a
    /// via alias — so it arrived in the entry list twice under one
    /// callsign. Everything downstream keys on the callsign, and the map's
    /// annotation reconciler trapped on the repeat. The heard entry must
    /// win: it is the station itself, where the alias is only a lead to it.
    func testAnAliasAlsoHeardDirectlyFoldsIntoTheHeardEntry() {
        var heardNode = entry("DRLNOD", latitude: 39.61, longitude: -104.71)
        heardNode.heardCount = 42
        let heard = [heardNode, entry("W0ARP-10", latitude: 39.7, longitude: -104.8)]

        var aliasNode = entry("DRLNOD", latitude: 39.62, longitude: -104.72)
        aliasNode.isNodeAlias = true
        let nodes = [aliasNode, {
            var other = entry("HORSE", latitude: 39.5, longitude: -104.6)
            other.isNodeAlias = true
            return other
        }()]

        let merged = HeardStationMap.addingAliases(nodes, toHeard: heard)
        XCTAssertEqual(merged.map(\.callsign).sorted(),
                       ["DRLNOD", "HORSE", "W0ARP-10"])
        let survivor = merged.first { $0.callsign == "DRLNOD" }
        XCTAssertEqual(survivor?.heardCount, 42,
                       "the heard entry must survive, not the alias lead")
        XCTAssertEqual(survivor?.isNodeAlias, false)
    }

    private func entry(_ callsign: String,
                       latitude: Double,
                       longitude: Double) -> HeardStationMap.Entry {
        var entry = HeardStationMap.Entry(callsign: callsign, heardCount: 1,
                                          lastHeard: nil, lastVia: [])
        entry.position = GreatCircle.Point(latitude: latitude, longitude: longitude)
        return entry
    }
}
