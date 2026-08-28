import XCTest
@testable import AXTerm

/// A NODES broadcast is a set of promises. These are the ones this station
/// can keep.
///
/// Built against the table AXTerm was actually advertising on 2026-08-27:
/// ten routes, every one inferred from overheard traffic, including
/// `KN6VV-1 via HORSE` where HORSE was not a neighbour at all.
final class NetRomAdvertisableRoutesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_787_880_000)

    private func route(
        _ destination: String, via origin: String, quality: Int = 60,
        ageSeconds: TimeInterval = 0, source: String = "inferred"
    ) -> RouteInfo {
        RouteInfo(destination: destination, origin: origin, quality: quality,
                  path: [origin, destination],
                  lastUpdated: now.addingTimeInterval(-ageSeconds), sourceType: source)
    }

    private func neighbor(
        _ call: String, quality: Int = 140, silentSeconds: TimeInterval = 0
    ) -> NeighborInfo {
        NeighborInfo(call: call, quality: quality,
                     lastSeen: now.addingTimeInterval(-silentSeconds))
    }

    /// The failure that started this: a route whose next hop we have no
    /// way to hand a packet to. Advertising it attracts traffic that dies.
    func testARouteThroughAStrangerIsNotAdvertised() {
        let decision = NetRomAdvertisableRoutes.decide(
            routes: [route("KN6VV-1", via: "HORSE")],
            neighbors: [neighbor("DRLNOD")],
            now: now)
        XCTAssertTrue(decision.advertisable.isEmpty)
        XCTAssertEqual(decision.withheld.first?.destination, "KN6VV-1")
    }

    func testARouteThroughALiveNeighbourIsAdvertised() {
        let decision = NetRomAdvertisableRoutes.decide(
            routes: [route("KB5YZB-1", via: "DRLNOD", quality: 23)],
            neighbors: [neighbor("DRLNOD")],
            now: now)
        XCTAssertEqual(decision.advertisable.map(\.destination), ["KB5YZB-1"])
        XCTAssertEqual(decision.advertisable.first?.quality, 23)
    }

    /// EVANS was four days old and still being promised.
    func testAStaleRouteIsNotAdvertised() {
        let decision = NetRomAdvertisableRoutes.decide(
            routes: [route("EVANS", via: "DRLNOD", ageSeconds: 4 * 24 * 3600)],
            neighbors: [neighbor("DRLNOD")],
            now: now)
        XCTAssertTrue(decision.advertisable.isEmpty)
    }

    /// A neighbour we have not heard in an hour is not somewhere we can
    /// promise to deliver, whatever the table says.
    func testASilentNeighbourStopsBeingAWayThrough() {
        let decision = NetRomAdvertisableRoutes.decide(
            routes: [route("KB5YZB-1", via: "DRLNOD")],
            neighbors: [neighbor("DRLNOD", silentSeconds: 3 * 3600)],
            now: now)
        XCTAssertTrue(decision.advertisable.isEmpty)
    }

    /// A route cannot be more reliable than the link it would ride over.
    func testQualityIsCappedByTheFirstHop() {
        let decision = NetRomAdvertisableRoutes.decide(
            routes: [route("KB5YZB-1", via: "DRLNOD", quality: 60)],
            neighbors: [neighbor("DRLNOD", quality: 30)],
            now: now)
        XCTAssertEqual(decision.advertisable.first?.quality, 30)
    }

    /// Our inference scale is not NET/ROM's. Publishing it raw enters this
    /// station into a comparison it has not earned.
    func testInferredQualityIsCappedBelowTheCeiling() {
        let decision = NetRomAdvertisableRoutes.decide(
            routes: [route("KB5YZB-1", via: "DRLNOD", quality: 200)],
            neighbors: [neighbor("DRLNOD", quality: 255)],
            now: now)
        XCTAssertEqual(decision.advertisable.first?.quality,
                       NetRomAdvertisableRoutes.inferredQualityCeiling)
    }

    /// A route another node broadcast is that node's own promise, on its
    /// own scale, and is passed along at the quality it was given.
    func testABroadcastRouteKeepsItsQuality() {
        let decision = NetRomAdvertisableRoutes.decide(
            routes: [route("KB5YZB-1", via: "DRLNOD", quality: 200, source: "broadcast")],
            neighbors: [neighbor("DRLNOD", quality: 255)],
            now: now)
        XCTAssertEqual(decision.advertisable.first?.quality, 200)
    }

    func testZeroQualityIsNotAPromise() {
        let decision = NetRomAdvertisableRoutes.decide(
            routes: [route("KB5YZB-1", via: "DRLNOD", quality: 0)],
            neighbors: [neighbor("DRLNOD")],
            now: now)
        XCTAssertTrue(decision.advertisable.isEmpty)
    }

    /// Case and padding come from wherever the table was filled from.
    func testNextHopMatchingIgnoresCaseAndPadding() {
        let decision = NetRomAdvertisableRoutes.decide(
            routes: [route("KB5YZB-1", via: " drlnod ")],
            neighbors: [neighbor("DRLNOD")],
            now: now)
        XCTAssertEqual(decision.advertisable.count, 1)
    }

    /// The whole table from the capture: one of ten survives.
    func testTheCapturedTableCollapsesToWhatWeCanCarry() {
        let routes = [
            route("EVANS", via: "DRLNOD", quality: 61, ageSeconds: 4 * 24 * 3600),
            route("KB5YZB-1", via: "DRLNOD", quality: 23),
            route("KB5YZB-7", via: "DRLNOD", quality: 16, ageSeconds: 30 * 24 * 3600),
            route("KC0LDY-10", via: "DRLNOD", quality: 29, ageSeconds: 4 * 24 * 3600),
            route("KN6VV-1", via: "HORSE", quality: 16),
            route("KN6VV-7", via: "HORSE", quality: 16)
        ]
        let decision = NetRomAdvertisableRoutes.decide(
            routes: routes, neighbors: [neighbor("DRLNOD", quality: 100)], now: now)
        XCTAssertEqual(decision.advertisable.map(\.destination), ["KB5YZB-1"])
        XCTAssertEqual(decision.withheld.count, 5)
    }
}
