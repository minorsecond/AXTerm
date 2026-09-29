import Foundation
import Combine
import MapKit

/// A map image captured while there was a network, kept for when there
/// is not.
///
/// MapKit has no public offline-tile API: you cannot ask it to keep a
/// region for later, and there is no supported way to reach its tile
/// cache. What *is* supported is `MKMapSnapshotter` — render a region to
/// an image now, store the image, and draw it later with markers
/// projected on top. That is what a POTA or SOTA operator actually
/// needs: pin the area you are going to before you leave the truck.
///
/// The projection is exact rather than approximate. `MKMapPoint` **is**
/// the Mercator projection MapKit used to render the snapshot, so
/// storing the `MKMapRect` and normalising against it puts a marker
/// exactly where MapKit would have.
nonisolated struct OfflineMapSnapshot: Codable, Equatable, Sendable, Identifiable {

    /// Operator-facing name, e.g. "Mount Evans" — also the file stem.
    var name: String
    /// The captured area, as MapKit's own projected rectangle.
    var originX: Double
    var originY: Double
    var width: Double
    var height: Double
    var capturedAt: Date
    /// Pixel size of the stored image.
    var pixelWidth: Double
    var pixelHeight: Double
    /// Which basemap this was rendered with, so the stored image is
    /// labelled with what it actually shows.
    var basemap: String = MapBasemap.standard.rawValue

    var id: String { name }

    var mapRect: MKMapRect {
        MKMapRect(x: originX, y: originY, width: width, height: height)
    }

    init(name: String, mapRect: MKMapRect, pixelSize: CGSize,
         basemap: MapBasemap = .standard, capturedAt: Date) {
        self.basemap = basemap.rawValue
        self.name = name
        self.originX = mapRect.origin.x
        self.originY = mapRect.origin.y
        self.width = mapRect.size.width
        self.height = mapRect.size.height
        self.pixelWidth = pixelSize.width
        self.pixelHeight = pixelSize.height
        self.capturedAt = capturedAt
    }

    /// Where a coordinate falls inside the snapshot, as 0…1 fractions of
    /// width and height. Outside 0…1 means outside the captured area —
    /// the caller decides whether to clip or to draw an edge marker.
    func unitPoint(for coordinate: GreatCircle.Point) -> (x: Double, y: Double) {
        let point = MKMapPoint(CLLocationCoordinate2D(
            latitude: coordinate.latitude, longitude: coordinate.longitude))
        guard width > 0, height > 0 else { return (0, 0) }
        return (x: (point.x - originX) / width,
                y: (point.y - originY) / height)
    }

    func contains(_ coordinate: GreatCircle.Point) -> Bool {
        let point = unitPoint(for: coordinate)
        return (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    /// Rough ground width, for the operator-facing size label.
    var kilometresWide: Double {
        let left = mapRect.origin.coordinate
        let right = MKMapPoint(x: originX + width, y: originY).coordinate
        return GreatCircle.kilometres(
            from: .init(latitude: left.latitude, longitude: left.longitude),
            to: .init(latitude: right.latitude, longitude: right.longitude))
    }
}

/// Stores snapshots on disk: a PNG plus a JSON index.
///
/// Deliberately plain files rather than the database — these are large
/// binaries whose whole purpose is to survive, and a file the operator
/// can see, copy to another machine, or delete is more useful than a
/// blob inside SQLite.
/// The on-disk library of captured maps: a PNG per snapshot plus a JSON
/// index.
///
/// A plain value type doing plain file I/O, so it is testable without a
/// view, an actor, or an observable wrapper. `OfflineMapStore` below is
/// the thin `ObservableObject` the UI binds to.
///
/// Files rather than the database on purpose — these are large binaries
/// whose whole point is to survive, and one the operator can see, copy
/// to another machine, or delete beats a blob inside SQLite.
nonisolated struct OfflineMapLibrary {

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true)
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("AXTerm/OfflineMaps", isDirectory: true)
    }

    var indexURL: URL { directory.appendingPathComponent("index.json") }

    func imageURL(for snapshot: OfflineMapSnapshot) -> URL {
        directory.appendingPathComponent(Self.fileStem(snapshot.name) + ".png")
    }

    /// File-safe stem for a name the operator typed — it must not
    /// collide, and must not escape the directory.
    static func fileStem(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = name.unicodeScalars.filter { allowed.contains($0) }
        let stem = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        return stem.isEmpty ? "map" : stem
    }

    func load() -> [OfflineMapSnapshot] {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([OfflineMapSnapshot].self, from: data)
        else { return [] }
        return decoded.sorted { $0.capturedAt > $1.capturedAt }
    }

    private func save(_ snapshots: [OfflineMapSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Adds a capture, replacing any with the same name rather than
    /// accumulating near-duplicates.
    @discardableResult
    func add(_ snapshot: OfflineMapSnapshot, png: Data) throws -> [OfflineMapSnapshot] {
        try png.write(to: imageURL(for: snapshot), options: .atomic)
        var snapshots = load()
        snapshots.removeAll { $0.name == snapshot.name }
        snapshots.insert(snapshot, at: 0)
        save(snapshots)
        return snapshots
    }

    @discardableResult
    func remove(_ snapshot: OfflineMapSnapshot) -> [OfflineMapSnapshot] {
        try? FileManager.default.removeItem(at: imageURL(for: snapshot))
        var snapshots = load()
        snapshots.removeAll { $0.name == snapshot.name }
        save(snapshots)
        return snapshots
    }

    /// The stored snapshot that best covers a position — the smallest
    /// one containing it, so a tight capture of the operating site wins
    /// over a wide regional one.
    func bestSnapshot(covering coordinate: GreatCircle.Point,
                      in snapshots: [OfflineMapSnapshot]? = nil) -> OfflineMapSnapshot? {
        (snapshots ?? load())
            .filter { $0.contains(coordinate) }
            .min { $0.width < $1.width }
    }
}

/// Observable wrapper the UI binds to.
final class OfflineMapStore: ObservableObject {

    @Published private(set) var snapshots: [OfflineMapSnapshot] = []
    let library: OfflineMapLibrary

    init(directory: URL? = nil) {
        library = OfflineMapLibrary(directory: directory)
        snapshots = library.load()
    }

    func imageURL(for snapshot: OfflineMapSnapshot) -> URL {
        library.imageURL(for: snapshot)
    }

    func add(_ snapshot: OfflineMapSnapshot, png: Data) throws {
        snapshots = try library.add(snapshot, png: png)
    }

    func remove(_ snapshot: OfflineMapSnapshot) {
        snapshots = library.remove(snapshot)
    }

    func bestSnapshot(covering coordinate: GreatCircle.Point) -> OfflineMapSnapshot? {
        library.bestSnapshot(covering: coordinate, in: snapshots)
    }
}

/// Captures a region using MapKit's snapshotter.
@MainActor
enum OfflineMapCapture {

    enum CaptureError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let reason): "Could not capture the map: \(reason)"
            }
        }
    }

    /// Renders `region` at `size` points and returns the snapshot plus
    /// its PNG. Requires a network — that is the point: you do this
    /// before you leave.
    static func capture(region: MKCoordinateRegion,
                        size: CGSize,
                        name: String,
                        basemap: MapBasemap = .standard,
                        now: Date = Date()) async throws -> (OfflineMapSnapshot, Data) {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.mapType = basemap.mkMapType
        options.showsBuildings = false

        let snapshotter = MKMapSnapshotter(options: options)
        let shot: MKMapSnapshotter.Snapshot
        do {
            shot = try await snapshotter.start()
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }

        guard let png = shot.image.platformPNGData() else {
            throw CaptureError.failed("the image could not be encoded")
        }

        // Store MapKit's own projected rect, so markers land exactly
        // where MapKit would have drawn them.
        let rect = MKMapRect(region: region)
        return (OfflineMapSnapshot(name: name, mapRect: rect, pixelSize: size,
                                   basemap: basemap, capturedAt: now), png)
    }
}

extension MKMapRect {
    /// The projected rectangle covering a coordinate region.
    init(region: MKCoordinateRegion) {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2))
        self.init(x: min(topLeft.x, bottomRight.x),
                  y: min(topLeft.y, bottomRight.y),
                  width: abs(bottomRight.x - topLeft.x),
                  height: abs(bottomRight.y - topLeft.y))
    }
}
