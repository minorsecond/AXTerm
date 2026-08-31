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

    /// The most tiles one request may fetch, however big the drawn box.
    ///
    /// About 260 MB and 64 sequential requests to a public service, which is
    /// already a lot to ask of it. The cap exists because a region is drawn
    /// by hand and a hand can draw a continent in two taps — the same shape
    /// of mistake that once had this fetching a strip from Utah to Virginia.
    /// A refusal that says how far over the line the request is beats a
    /// download that quietly runs all afternoon.
    static let maximumTilesPerRequest = 64

    /// Tiles under a drawn region, capped.
    static func tilesWorthFetching(covering region: MKCoordinateRegion)
        -> (tiles: [(lat: Int, lon: Int)], wasCapped: Bool) {
        let all = ElevationDownloader.tiles(covering: region)
        guard all.count > maximumTilesPerRequest else { return (all, false) }
        return (Array(all.prefix(maximumTilesPerRequest)), true)
    }

    /// What fetching a drawn region would cost.
    func estimate(covering region: MKCoordinateRegion) -> Estimate {
        let requested = ElevationDownloader.tiles(covering: region)
        let capped = Self.tilesWorthFetching(covering: region)
        let missing = capped.tiles.filter { tile in
            (try? store?.hasTile(lat: tile.lat, lon: tile.lon)) != true
        }
        return Estimate(tileCount: missing.count,
                        byteCount: Int64(missing.count) * Self.bytesPerTile,
                        requestedTileCount: requested.count,
                        wasCapped: capped.wasCapped)
    }

    func download(covering region: MKCoordinateRegion) {
        downloader?.download(tiles: Self.tilesWorthFetching(covering: region).tiles)
    }

    /// A tile is `tileSamples` squared 32-bit floats. That is the number that
    /// matters — the GeoTIFF on the wire compresses, the stored grid does not.
    static var bytesPerTile: Int64 {
        Int64(ElevationStore.tileSamples) * Int64(ElevationStore.tileSamples) * 4
    }

    /// What a download would actually cost, before starting it.
    /// Identifiable so it can drive a sheet directly: the thing being asked
    /// about *is* the cost, and carrying a separate flag beside it would let
    /// the two disagree.
    struct Estimate: Equatable, Identifiable {
        var id: String { "\(tileCount)/\(byteCount)/\(requestedTileCount)" }
        var tileCount: Int
        var byteCount: Int64
        /// How many tiles the region actually covers, before any cap.
        var requestedTileCount: Int = 0
        /// True when the request was trimmed to fit the per-request cap.
        /// Surfaced rather than silently applied — a cap the operator cannot
        /// see reads as coverage they did not get.
        var wasCapped: Bool = false

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
        return Estimate(tileCount: missing.count,
                        byteCount: Int64(missing.count) * Self.bytesPerTile,
                        requestedTileCount: tiles.count)
    }

    /// Downloads terrain around one station.
    func download(around observer: GreatCircle.Point) {
        downloader?.download(tiles: Self.tilesWorthFetching(around: observer))
    }

    /// What one path's profile needs, and what it would cost.
    ///
    /// A path is one or two tiles. Making the operator find the map, draw a
    /// region and download a state before a station page can say anything
    /// about terrain is a lot of ceremony for eight megabytes — and it makes
    /// the feature depend on a map page they may never open.
    func estimate(alongPathFrom origin: GreatCircle.Point,
                  to destination: GreatCircle.Point) -> Estimate {
        let tiles = ElevationDownloader.tiles(alongPathFrom: origin, to: destination)
        let missing = tiles.filter { tile in
            (try? store?.hasTile(lat: tile.lat, lon: tile.lon)) != true
        }
        return Estimate(tileCount: missing.count,
                        byteCount: Int64(missing.count) * Self.bytesPerTile,
                        requestedTileCount: tiles.count)
    }

    /// Fetches exactly the tiles one path crosses.
    func download(alongPathFrom origin: GreatCircle.Point,
                  to destination: GreatCircle.Point) {
        downloader?.download(
            tiles: ElevationDownloader.tiles(alongPathFrom: origin, to: destination))
    }

    /// The standing preference: keep terrain for wherever this station is.
    /// On means fetch without asking again; off means never.
    static let autoFetchEnabledKey = "elevation.autoFetchHome"

    /// Whether the question has ever been put. Asked once in the life of the
    /// install, not once per grid square — the operator is answering "should
    /// this app keep terrain for my area", and that answer does not expire
    /// because they corrected a typo in their locator or drove to a
    /// neighbouring square.
    static let askedKey = "elevation.homeFetchAsked"

    /// Whether to put the question now.
    ///
    /// Separated from the store so the policy is testable without an
    /// elevation database. Everything here is a reason *not* to ask.
    static func shouldAskAboutHomeTerrain(gridSquare: String,
                                          observer: GreatCircle.Point,
                                          defaults: UserDefaults = .standard) -> Bool {
        guard !normalizedGrid(gridSquare).isEmpty else { return false }
        guard !defaults.bool(forKey: askedKey) else { return false }
        // 3DEP is a USGS product covering the United States and its
        // territories; elsewhere it answers with a tile of NaN. Asking
        // someone in Copenhagen to spend 36 MB on that is worse than not
        // asking at all — and it must not burn the one question either, in
        // case they later move somewhere it would help.
        return ElevationDownloader.sourceHasCoverage(at: observer)
    }

    static func normalizedGrid(_ gridSquare: String) -> String {
        gridSquare.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// The question, when it is live and there is something to fetch.
    func homeTerrainOffer(around observer: GreatCircle.Point,
                          gridSquare: String,
                          defaults: UserDefaults = .standard) -> Estimate? {
        guard store != nil,
              Self.shouldAskAboutHomeTerrain(gridSquare: gridSquare,
                                             observer: observer,
                                             defaults: defaults)
        else { return nil }
        let estimate = self.estimate(around: observer)
        return estimate.tileCount > 0 ? estimate : nil
    }

    /// Yes. Downloads now as an asked-for fetch — they saw the size and
    /// pressed the button — and stands as the preference from here on.
    func acceptHomeTerrain(around observer: GreatCircle.Point,
                           defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: Self.askedKey)
        defaults.set(true, forKey: Self.autoFetchEnabledKey)
        download(around: observer)
    }

    /// No. Not asked again; the Settings toggle and every station page are
    /// still there for anyone who changes their mind.
    func declineHomeTerrain(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: Self.askedKey)
        defaults.set(false, forKey: Self.autoFetchEnabledKey)
    }

    /// Terrain for a grid the operator has moved to, under a preference they
    /// already gave.
    ///
    /// Automatic, so it refuses expensive and constrained networks. Agreeing
    /// once to "keep terrain for my area" is not agreeing to 36 MB over a
    /// hotspot in a car park, and a portable operator is exactly who ends up
    /// in one.
    func fetchHomeTerrainIfEnabled(around observer: GreatCircle.Point,
                                   defaults: UserDefaults = .standard) {
        guard store != nil, defaults.bool(forKey: Self.askedKey) else { return }
        guard defaults.bool(forKey: Self.autoFetchEnabledKey) else { return }
        guard ElevationDownloader.sourceHasCoverage(at: observer) else { return }
        let wanted = Self.tilesWorthFetching(around: observer).filter { tile in
            (try? store?.hasTile(lat: tile.lat, lon: tile.lon)) != true
        }
        guard !wanted.isEmpty else { return }
        downloader?.download(tiles: wanted, automatic: true)
    }

    func cancelDownload() {
        downloader?.cancel()
    }

    func deleteAll() {
        try? store?.removeAllTiles()
        refresh()
    }
}
