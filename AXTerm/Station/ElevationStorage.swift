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

    /// Whether the offer is made at all. On by default; the Settings toggle
    /// writes here. Off means never ask and never fetch.
    static let autoFetchEnabledKey = "elevation.autoFetchHome"

    /// What was decided for a given grid square, so the question is asked
    /// once and an answer is respected.
    static func decisionKey(_ grid: String) -> String {
        "elevation.homeFetchDecision.\(grid)"
    }

    /// Whether to ask the operator for the ground around their station.
    ///
    /// Terrain used to work only if you knew a map page had an offline menu
    /// with a terrain section in it — not a feature anyone discovers. VHF
    /// packet is local, so nine tiles around the station cover every path it
    /// will realistically be asked about, and having them should be the
    /// default state of the app.
    ///
    /// Downloading them silently is a different matter. It is tens of
    /// megabytes from a US government service, and the operator is the one
    /// who knows whether their connection can afford it and whether they want
    /// to make that request at all. So: offered, once, with the cost on the
    /// face of it.
    ///
    /// Nil when there is nothing to ask about — no grid, no store, nothing
    /// missing, already answered, or outside the only region the source
    /// covers.
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

    /// Whether the question is live, separated from the store so the policy
    /// can be tested without one. Everything here is a reason *not* to ask.
    static func shouldAskAboutHomeTerrain(gridSquare: String,
                                          observer: GreatCircle.Point,
                                          defaults: UserDefaults = .standard) -> Bool {
        let grid = normalizedGrid(gridSquare)
        guard !grid.isEmpty else { return false }
        // Off means never ask. Checked before the answered-already lookup, so
        // switching it back on asks again.
        guard defaults.object(forKey: autoFetchEnabledKey) as? Bool ?? true else { return false }
        // Asked and answered. A move to another grid is a new question.
        guard defaults.string(forKey: decisionKey(grid)) == nil else { return false }
        // 3DEP is a USGS product covering the United States and its
        // territories; elsewhere it answers with a tile of NaN. Asking
        // someone in Copenhagen to spend 36 MB on that is worse than not
        // asking at all.
        return ElevationDownloader.sourceHasCoverage(at: observer)
    }

    /// One square, one answer — "dm79po" and "DM79PO" are the same ground,
    /// and keying the decision on the raw string would re-ask on a re-typed
    /// grid.
    static func normalizedGrid(_ gridSquare: String) -> String {
        gridSquare.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// The operator said yes. Downloads as an asked-for fetch, because it
    /// was one — they saw the size and pressed the button.
    func acceptHomeTerrain(around observer: GreatCircle.Point,
                           gridSquare: String,
                           defaults: UserDefaults = .standard) {
        let grid = Self.normalizedGrid(gridSquare)
        guard !grid.isEmpty else { return }
        defaults.set("accepted", forKey: Self.decisionKey(grid))
        download(around: observer)
    }

    /// The operator said no. Remembered per grid, so the question is not
    /// asked again here — the Settings section and every station page still
    /// offer terrain to anyone who changes their mind.
    func declineHomeTerrain(gridSquare: String, defaults: UserDefaults = .standard) {
        let grid = Self.normalizedGrid(gridSquare)
        guard !grid.isEmpty else { return }
        defaults.set("declined", forKey: Self.decisionKey(grid))
    }

    func cancelDownload() {
        downloader?.cancel()
    }

    func deleteAll() {
        try? store?.removeAllTiles()
        refresh()
    }
}
