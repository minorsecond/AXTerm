import GRDB
import XCTest
@testable import AXTerm

/// Every version of every hazard, kept append-only with its provenance
/// (Docs/HazardLayers.md §8), for a time slider and after-action exports.
final class HazardHistoryStoreTests: XCTestCase {
    private var queue: DatabaseQueue!
    private var store: SQLiteHazardHistoryStore!
    private let t0 = Date(timeIntervalSince1970: 1_791_590_000)

    override func setUpWithError() throws {
        queue = try DatabaseQueue()
        try DatabaseManager.migrator.migrate(queue)
        store = SQLiteHazardHistoryStore(dbQueue: queue)
    }

    private func p(_ lat: Double, _ lon: Double) -> GreatCircle.Point {
        GreatCircle.Point(latitude: lat, longitude: lon)
    }

    private func warning(_ id: String, issued: TimeInterval, expires: TimeInterval,
                         fetched: TimeInterval = 0, references: [String] = []) -> HazardFeature {
        var feature = HazardFeature(id: id, kind: .warning, event: "Red Flag Warning",
                                    source: "NWS Boulder CO", fetchedAt: t0.addingTimeInterval(fetched))
        feature.issued = t0.addingTimeInterval(issued)
        feature.expires = t0.addingTimeInterval(expires)
        feature.geometry = .polygons([[[p(39, -105), p(39, -104), p(40, -104)]]])
        feature.properties = ["areaDesc": "Elbert; Douglas"]
        if !references.isEmpty {
            let list = references.map { ["identifier": $0] }
            let json = try! JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
            feature.properties["references"] = String(data: json, encoding: .utf8)
        }
        return feature
    }

    private func perimeter(_ shift: Double, fetched: TimeInterval) -> HazardFeature {
        var feature = HazardFeature(id: "fire-1", kind: .firePerimeter, event: "Wildfire",
                                    source: "NIFC", fetchedAt: t0.addingTimeInterval(fetched))
        feature.geometry = .polygons([[[p(39 + shift, -105), p(39, -104), p(40, -104)]]])
        return feature
    }

    func testTheSameFetchTwiceIsOneRow() throws {
        try store.record([warning("A", issued: 0, expires: 3600)])
        try store.record([warning("A", issued: 0, expires: 3600, fetched: 120)])
        let rows = try store.versions(of: "A")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.feature.fetchedAt, t0, "first seen")
        XCTAssertEqual(rows.first?.lastSeen, t0.addingTimeInterval(120))
    }

    /// A perimeter is kept when its shape changes, not on every fetch.
    func testAFirePerimeterIsKeptWhenItsShapeChanges() throws {
        try store.record([perimeter(0, fetched: 0)])
        try store.record([perimeter(0, fetched: 300)])
        try store.record([perimeter(0.1, fetched: 600)])
        XCTAssertEqual(try store.versions(of: "fire-1").count, 2)
    }

    func testWhatWasInEffectAtAMoment() throws {
        try store.record([warning("A", issued: 0, expires: 3600),
                          warning("B", issued: 7200, expires: 9000)])
        XCTAssertEqual(try store.inEffect(at: t0.addingTimeInterval(1800)).map(\.id), ["A"])
        XCTAssertEqual(try store.inEffect(at: t0.addingTimeInterval(5000)).map(\.id), [])
        XCTAssertEqual(try store.inEffect(at: t0.addingTimeInterval(8000)).map(\.id), ["B"])
    }

    /// An NWS update names the message it replaces; from the update's issue
    /// time the old one is no longer what was in effect.
    func testAnUpdateReplacesTheMessageItReferences() throws {
        try store.record([warning("A", issued: 0, expires: 3600),
                          warning("A2", issued: 1200, expires: 5400, references: ["A"])])
        XCTAssertEqual(try store.inEffect(at: t0.addingTimeInterval(600)).map(\.id), ["A"])
        XCTAssertEqual(try store.inEffect(at: t0.addingTimeInterval(1800)).map(\.id), ["A2"])
    }

    func testAFeatureComesBackWhole() throws {
        let original = warning("A", issued: 0, expires: 3600)
        try store.record([original])
        let back = try XCTUnwrap(try store.versions(of: "A").first?.feature)
        XCTAssertEqual(back, original)
    }
}
