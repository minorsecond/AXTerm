import Foundation
import Combine
import MapKit

/// Owns the elevation database and keeps its coverage legible to the UI.
///
/// Split from `ElevationStore` for the same reason the basemap store is:
/// the store is a plain non-isolated class so a terrain profile can sample it
/// from a background thread, and making it the observable object would put a
/// `@MainActor` type's deallocation on whatever thread finished with it last.
@MainActor
final class ElevationStorage: ObservableObject {

    @Published private(set) var tileCount = 0
    @Published private(set) var byteSize: Int64 = 0
    @Published private(set) var openError: String?
    /// Republished from the downloader.
    ///
    /// The view observes *this* object; the downloader is a plain property,
    /// so reading `downloader.state` from a view body compiles and then never
    /// updates. Mirroring it here is what makes the progress bar move.
    @Published private(set) var downloadState: ElevationDownloader.State = .idle

    private(set) var store: ElevationStore?
    let downloader: ElevationDownloader?

    private var cancellables: Set<AnyCancellable> = []

    nonisolated static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("AXTerm", isDirectory: true)
            .appendingPathComponent("elevation.sqlite")
    }

    init(url: URL = ElevationStorage.defaultURL()) {
        let opened = try? ElevationStore(url: url)
        self.store = opened
        self.downloader = opened.map(ElevationDownloader.init(store:))
        if opened == nil {
            openError = "The elevation store at \(url.path) could not be opened."
        }
        refresh()

        downloader?.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.downloadState = state
                switch state {
                case .finished, .failed: self?.refresh()
                default: break
                }
            }
            .store(in: &cancellables)
    }

    var hasTerrain: Bool { tileCount > 0 }

    func refresh() {
        guard let store else { return }
        tileCount = (try? store.tileCount()) ?? 0
        byteSize = (try? FileManager.default
            .attributesOfItem(atPath: store.url.path)[.size] as? Int64) as? Int64 ?? 0
    }

    /// How far from the station terrain is worth having.
    ///
    /// Matches the range beyond which `PredictedPath` stops evaluating paths.
    /// A degree of latitude is about 111 km, so one ring of tiles around the
    /// station covers every path this feature will ever judge. Downloading
    /// past it is bytes that answer no question the app asks.
    static let usefulRadiusDegrees = 1.1

    /// The tiles worth fetching for a station at this position.
    ///
    /// Deliberately keyed on the *station*, not on a bounding box of everyone
    /// heard. Those are wildly different things: one distant station drags a
    /// bounding box across a continent, and the first version of this button
    /// cheerfully began downloading a strip from Utah to Virginia because of
    /// it. At most nine tiles come out of here.
    static func tilesWorthFetching(around observer: GreatCircle.Point) -> [(lat: Int, lon: Int)] {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: observer.latitude,
                                           longitude: observer.longitude),
            span: MKCoordinateSpan(latitudeDelta: usefulRadiusDegrees * 2,
                                   longitudeDelta: usefulRadiusDegrees * 2))
        return ElevationDownloader.tiles(covering: region)
    }

    /// What a download would actually cost, before starting it.
    struct Estimate: Equatable {
        var tileCount: Int
        var byteCount: Int64

        var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        }
    }

    /// Tiles not already stored, and what they weigh.
    func estimate(around observer: GreatCircle.Point) -> Estimate {
        let tiles = Self.tilesWorthFetching(around: observer)
        let missing = tiles.filter { tile in
            (try? store?.hasTile(lat: tile.lat, lon: tile.lon)) != true
        }
        // A tile is `tileSamples` squared 32-bit floats, which is the number
        // that matters — the GeoTIFF on the wire compresses, the stored grid
        // does not.
        let perTile = Int64(ElevationStore.tileSamples) * Int64(ElevationStore.tileSamples) * 4
        return Estimate(tileCount: missing.count,
                        byteCount: Int64(missing.count) * perTile)
    }

    /// Downloads terrain around one station.
    func download(around observer: GreatCircle.Point) {
        downloader?.download(tiles: Self.tilesWorthFetching(around: observer))
    }

    func cancelDownload() {
        downloader?.cancel()
    }

    func deleteAll() {
        try? store?.removeAllTiles()
        refresh()
    }
}
