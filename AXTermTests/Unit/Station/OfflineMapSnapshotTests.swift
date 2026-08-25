import XCTest
import MapKit
@testable import AXTerm

final class OfflineMapSnapshotTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Denver-ish, roughly a degree across.
    private func snapshot(name: String = "Test") -> OfflineMapSnapshot {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.7, longitude: -105.0),
            span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0))
        return OfflineMapSnapshot(
            name: name, mapRect: MKMapRect(region: region),
            pixelSize: CGSize(width: 1600, height: 1200),
            basemap: .standard, capturedAt: now)
    }

    // MARK: - Projection

    /// The centre of the captured region lands at the centre of the
    /// image. This is the property that makes markers land where MapKit
    /// would have drawn them.
    func testRegionCentreMapsToImageCentre() {
        let point = snapshot().unitPoint(
            for: .init(latitude: 39.7, longitude: -105.0))
        XCTAssertEqual(point.x, 0.5, accuracy: 0.002)
        XCTAssertEqual(point.y, 0.5, accuracy: 0.002)
    }

    /// North is up and east is right, in image coordinates where y grows
    /// downward — the axis a sign error flips.
    func testNorthIsUpAndEastIsRight() {
        let shot = snapshot()
        let north = shot.unitPoint(for: .init(latitude: 40.1, longitude: -105.0))
        let east = shot.unitPoint(for: .init(latitude: 39.7, longitude: -104.6))
        XCTAssertLessThan(north.y, 0.5, "north must be nearer the top")
        XCTAssertGreaterThan(east.x, 0.5, "east must be nearer the right")
    }

    func testContainsAcceptsInsideAndRejectsOutside() {
        let shot = snapshot()
        XCTAssertTrue(shot.contains(.init(latitude: 39.7, longitude: -105.0)))
        XCTAssertTrue(shot.contains(.init(latitude: 40.0, longitude: -104.7)))
        XCTAssertFalse(shot.contains(.init(latitude: 51.5, longitude: -0.12)))
        XCTAssertFalse(shot.contains(.init(latitude: 39.7, longitude: -110.0)))
    }

    /// A station outside the captured area yields a point outside 0…1
    /// rather than being silently clamped onto the edge, so the caller
    /// can tell the difference.
    func testOutsidePointsFallOutsideTheUnitRange() {
        let point = snapshot().unitPoint(for: .init(latitude: 39.7, longitude: -110.0))
        XCTAssertLessThan(point.x, 0)
    }

    func testGroundWidthIsPlausible() {
        // A degree of longitude at 40°N is about 85 km.
        XCTAssertEqual(snapshot().kilometresWide, 85, accuracy: 15)
    }

    func testRoundTripsThroughCoding() throws {
        let original = snapshot(name: "Mount Evans")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OfflineMapSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.basemap, MapBasemap.standard.rawValue)
    }

    // MARK: - File naming

    /// Names come from the operator, so they have to survive becoming a
    /// filename without colliding or escaping the directory.
    func testFileStemsAreSafe() {
        XCTAssertEqual(OfflineMapLibrary.fileStem("Mount Evans"), "Mount_Evans")
        XCTAssertEqual(OfflineMapLibrary.fileStem("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(OfflineMapLibrary.fileStem("DM79po 8/24"), "DM79po_824")
        XCTAssertEqual(OfflineMapLibrary.fileStem("   "), "map")
        XCTAssertEqual(OfflineMapLibrary.fileStem("///"), "map")
    }

    // MARK: - Store

    func testStoreRoundTripsAndReplacesByName() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-offline-test-\(UUID().uuidString)")
        let store = OfflineMapLibrary(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let png = Data("not really a png".utf8)
        _ = try store.add(snapshot(name: "Evans"), png: png)
        XCTAssertEqual(store.load().count, 1)

        // Re-capturing the same name replaces rather than accumulating.
        _ = try store.add(snapshot(name: "Evans"), png: png)
        XCTAssertEqual(store.load().count, 1)

        _ = try store.add(snapshot(name: "Bierstadt"), png: png)
        XCTAssertEqual(store.load().count, 2)

        // A fresh store reads what the first one wrote.
        let reopened = OfflineMapLibrary(directory: directory)
        XCTAssertEqual(Set(reopened.load().map(\.name)), ["Evans", "Bierstadt"])
    }

    /// The tightest capture covering a position wins — a detailed
    /// summit map beats a regional one.
    func testBestSnapshotPrefersTheTighterCapture() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-offline-test-\(UUID().uuidString)")
        let store = OfflineMapLibrary(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        func shot(_ name: String, span: Double) -> OfflineMapSnapshot {
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 39.7, longitude: -105.0),
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
            return OfflineMapSnapshot(
                name: name, mapRect: MKMapRect(region: region),
                pixelSize: CGSize(width: 100, height: 100),
                basemap: .standard, capturedAt: now)
        }
        _ = try store.add(shot("wide", span: 4), png: Data("x".utf8))
        _ = try store.add(shot("tight", span: 0.2), png: Data("x".utf8))

        let best = store.bestSnapshot(covering: .init(latitude: 39.7, longitude: -105.0))
        XCTAssertEqual(best?.name, "tight")
    }

    func testRemovingDeletesTheImageToo() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-offline-test-\(UUID().uuidString)")
        let store = OfflineMapLibrary(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = snapshot(name: "Evans")
        _ = try store.add(target, png: Data("x".utf8))
        let url = store.imageURL(for: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        _ = store.remove(target)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
