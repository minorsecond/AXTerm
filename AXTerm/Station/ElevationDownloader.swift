import Foundation
import Combine
import MapKit

/// Fetches elevation grids from USGS 3DEP and stores them for offline use.
///
/// Public-domain federal data, no API key, and — unlike the community tile
/// servers — no policy against retrieving a region in advance. The service
/// exports float32 GeoTIFF at an arbitrary bounding box and pixel size, which
/// is exactly the shape this needs: one request per tile.
///
/// US coverage only. That is stated rather than discovered: outside the US
/// the export returns nothing useful, and an operator elsewhere should be told
/// so instead of watching a download produce empty tiles.
@MainActor
final class ElevationDownloader: ObservableObject {

    enum State: Equatable {
        case idle
        case downloading(completed: Int, total: Int)
        case finished(tiles: Int)
        case failed(String)

        var isBusy: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle

    /// One tile at a time. These are multi-megabyte renders on somebody
    /// else's server, and a region is a handful of them — parallelism would
    /// buy seconds and cost goodwill.
    static let requestTimeout: TimeInterval = 120

    /// Above this many tiles, ask before starting. Each tile is a square
    /// degree and about 4 MB stored, so a full ring around one station —
    /// twelve tiles, near 50 MB, twelve sequential requests to somebody
    /// else's server — lands above it and gets confirmed. That is the
    /// intent: the common case asks, rather than only the pathological one.
    static let largeRegionTileCount = 6

    private let store: ElevationStore
    private var task: Task<Void, Never>?

    init(store: ElevationStore) {
        self.store = store
    }

    /// Tiles a region touches.
    static func tiles(covering region: MKCoordinateRegion) -> [(lat: Int, lon: Int)] {
        let north = region.center.latitude + region.span.latitudeDelta / 2
        let south = region.center.latitude - region.span.latitudeDelta / 2
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let east = region.center.longitude + region.span.longitudeDelta / 2

        let latRange = Int(floor(south))...Int(floor(north))
        let lonRange = Int(floor(west))...Int(floor(east))
        return latRange.flatMap { lat in lonRange.map { (lat: lat, lon: $0) } }
    }

    /// Every tile along a path, which is what a single profile actually needs.
    ///
    /// Far cheaper than a bounding box for a long path: a 100 km link across
    /// a corner touches two tiles, where its bounding box touches four.
    static func tiles(alongPathFrom origin: GreatCircle.Point,
                      to destination: GreatCircle.Point) -> [(lat: Int, lon: Int)] {
        var seen: Set<String> = []
        var result: [(lat: Int, lon: Int)] = []
        for point in GreatCircle.samplePath(from: origin, to: destination, count: 64) {
            let index = ElevationStore.tileIndex(for: point)
            if seen.insert("\(index.lat)/\(index.lon)").inserted {
                result.append(index)
            }
        }
        return result
    }

    func download(tiles: [(lat: Int, lon: Int)]) {
        cancel()
        task = Task { [weak self] in await self?.run(tiles: tiles) }
    }

    private func run(tiles: [(lat: Int, lon: Int)]) async {
        let missing = tiles.filter { (try? store.hasTile(lat: $0.lat, lon: $0.lon)) != true }
        guard !missing.isEmpty else {
            state = .finished(tiles: 0)
            return
        }

        state = .downloading(completed: 0, total: missing.count)
        var stored = 0

        for (index, tile) in missing.enumerated() {
            if Task.isCancelled { state = .idle; return }
            do {
                let grid = try await fetch(lat: tile.lat, lon: tile.lon)
                try store.store(lat: tile.lat, lon: tile.lon,
                                samples: ElevationStore.tileSamples, grid: grid)
                stored += 1
            } catch {
                // One failed tile leaves a hole, and a hole makes every path
                // through it report "unknown" rather than guessing — so the
                // download continues and the gap is visible where it matters.
                continue
            }
            state = .downloading(completed: index + 1, total: missing.count)
        }

        state = stored == 0
            ? .failed("No elevation data was returned. USGS 3DEP covers the United States; outside it, terrain analysis is unavailable.")
            : .finished(tiles: stored)
    }

    func cancel() {
        task?.cancel()
        task = nil
        if state.isBusy { state = .idle }
    }

    // MARK: - Fetching

    enum FetchError: Error {
        case badResponse
        case notFloatRaster
    }

    /// One tile from the 3DEP image service, as a float32 GeoTIFF.
    private func fetch(lat: Int, lon: Int) async throws -> [Float] {
        let bounds = ElevationStore.bounds(lat: lat, lon: lon)
        let samples = ElevationStore.tileSamples

        var components = URLComponents(string:
            "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer/exportImage")!
        components.queryItems = [
            .init(name: "bbox", value: "\(bounds.west),\(bounds.south),\(bounds.east),\(bounds.north)"),
            .init(name: "bboxSR", value: "4326"),
            .init(name: "imageSR", value: "4326"),
            .init(name: "size", value: "\(samples),\(samples)"),
            .init(name: "format", value: "tiff"),
            .init(name: "pixelType", value: "F32"),
            // Values outside coverage come back as NaN rather than a
            // plausible-looking number.
            .init(name: "noDataInterpretation", value: "esriNoDataMatchAny"),
            .init(name: "interpolation", value: "RSP_BilinearInterpolation"),
            .init(name: "f", value: "image"),
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Self.requestTimeout
        request.setValue("AXTerm/1.0 (packet radio terminal)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.badResponse
        }
        return try GeoTIFFReader.floatGrid(from: data, expecting: samples)
    }
}
