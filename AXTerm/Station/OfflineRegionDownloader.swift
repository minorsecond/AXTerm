import Foundation
import MapKit
import Combine

/// Downloads a region's tiles for offline use, or imports an `.mbtiles` file
/// that already contains them.
///
/// Refuses sources whose terms forbid bulk downloading, and says which term
/// it is refusing on. That refusal is the point of the type: the alternative
/// is an app that quietly hammers a volunteer-run tile server on the
/// operator's behalf and gets their IP blocked.
@MainActor
final class OfflineRegionDownloader: ObservableObject {

    enum State: Equatable {
        case idle
        case estimating
        /// `completed` of `total` tiles.
        case downloading(completed: Int, total: Int)
        case importing
        case finished(tiles: Int, bytes: Int)
        case failed(String)
        /// The source's terms forbid it. Carries the provider's own reason.
        case refused(String)

        var isBusy: Bool {
            switch self {
            case .estimating, .downloading, .importing: true
            default: false
            }
        }

        var progress: Double? {
            guard case .downloading(let completed, let total) = self, total > 0 else { return nil }
            return Double(completed) / Double(total)
        }
    }

    @Published private(set) var state: State = .idle

    /// Concurrent requests. Deliberately small: these are shared community
    /// servers, and the difference between four connections and forty is
    /// nothing to the operator and a great deal to the provider.
    static let maximumConcurrentRequests = 4

    /// Refuses to start a download larger than this without an explicit
    /// confirmation, because the operator cannot see a tile count and know
    /// what it means.
    static let largeDownloadTileThreshold = 20_000

    private let store: MapTileStore
    private var task: Task<Void, Never>?

    init(store: MapTileStore) {
        self.store = store
    }

    // MARK: - Estimating

    /// What a region would cost, before committing to it.
    struct Estimate: Equatable, Sendable {
        var tileCount: Int
        var estimatedBytes: Int
        var isLarge: Bool

        var sizeDescription: String {
            ByteCount.string(Int64(estimatedBytes))
        }
    }

    static func estimate(region: MKCoordinateRegion, zoomRange: ClosedRange<Int>) -> Estimate {
        let count = MapTileMath.tileCount(covering: region, zoomRange: zoomRange)
        return Estimate(tileCount: count,
                        estimatedBytes: MapTileMath.estimatedBytes(tileCount: count),
                        isLarge: count > largeDownloadTileThreshold)
    }

    // MARK: - Downloading

    func download(region: MKCoordinateRegion,
                  zoomRange: ClosedRange<Int>,
                  source: MapTileSource) {
        guard source.permitsBulkDownload else {
            state = .refused(source.bulkDownloadNote ??
                "\(source.name) does not permit downloading regions in advance.")
            return
        }
        guard source.isNetworkBacked else {
            state = .failed("\(source.name) has no server to download from. Import a file instead.")
            return
        }

        cancel()
        task = Task { [weak self] in
            await self?.run(region: region, zoomRange: zoomRange, source: source)
        }
    }

    private func run(region: MKCoordinateRegion,
                     zoomRange: ClosedRange<Int>,
                     source: MapTileSource) async {
        state = .estimating

        // Clamp to what the provider actually has: asking beyond it returns
        // errors the operator would have to interpret as a failure when it is
        // simply the edge of the data.
        let clamped = zoomRange.lowerBound...min(zoomRange.upperBound, source.maximumZoom)
        guard clamped.lowerBound <= clamped.upperBound else {
            state = .failed("\(source.name) has no tiles at that zoom level.")
            return
        }

        let wanted = MapTileMath.tiles(covering: region, zoomRange: clamped)
        // Skip what is already stored so a resumed download does not re-fetch
        // — the operator's connection is usually the scarce resource.
        let missing = wanted.filter { (try? store.hasTile(z: $0.z, x: $0.x, y: $0.y)) != true }

        guard !missing.isEmpty else {
            let stats = (try? store.statistics()) ?? .init(tileCount: 0, byteSize: 0,
                                                           minimumZoom: nil, maximumZoom: nil)
            state = .finished(tiles: 0, bytes: stats.byteSize)
            return
        }

        state = .downloading(completed: 0, total: missing.count)

        var completed = 0
        var storedBytes = 0
        var batch: [(z: Int, x: Int, y: Int, data: Data)] = []
        let session = URLSession(configuration: .ephemeral)

        // Chunked rather than one big task group: a group of 50,000 child
        // tasks costs more memory than the tiles do.
        for chunk in missing.chunked(into: Self.maximumConcurrentRequests) {
            if Task.isCancelled { state = .idle; return }

            let results = await withTaskGroup(of: (z: Int, x: Int, y: Int, data: Data?).self) { group in
                for tile in chunk {
                    group.addTask {
                        guard let url = source.url(z: tile.z, x: tile.x, y: tile.y) else {
                            return (tile.z, tile.x, tile.y, nil)
                        }
                        var request = URLRequest(url: url)
                        request.setValue("AXTerm/1.0 (packet radio terminal; +https://github.com/minorsecond/AXTerm)",
                                         forHTTPHeaderField: "User-Agent")
                        guard let (data, response) = try? await session.data(for: request),
                              let http = response as? HTTPURLResponse, http.statusCode == 200,
                              !data.isEmpty else {
                            return (tile.z, tile.x, tile.y, nil)
                        }
                        return (tile.z, tile.x, tile.y, data)
                    }
                }
                var collected: [(z: Int, x: Int, y: Int, data: Data?)] = []
                for await result in group { collected.append(result) }
                return collected
            }

            for result in results {
                completed += 1
                guard let data = result.data else { continue }
                batch.append((result.z, result.x, result.y, data))
                storedBytes += data.count
            }

            if batch.count >= 256 {
                try? store.store(batch)
                batch.removeAll(keepingCapacity: true)
            }
            state = .downloading(completed: completed, total: missing.count)
        }

        try? store.store(batch)
        try? store.setMetadata(source.id, for: "axterm_source")
        try? store.setMetadata(source.attribution, for: "attribution")
        try? store.setMetadata("AXTerm offline basemap", for: "name")
        try? store.setMetadata("baselayer", for: "type")
        try? store.setMetadata("1.3", for: "version")
        try? store.setMetadata("png", for: "format")

        state = .finished(tiles: completed, bytes: storedBytes)
    }

    func cancel() {
        task?.cancel()
        task = nil
        if state.isBusy { state = .idle }
    }

    // MARK: - Importing

    /// Copies an `.mbtiles` file's tiles into the store.
    ///
    /// Reading the file directly would be faster, but the operator picked it
    /// out of Files or a Downloads folder: on iOS that URL is a
    /// security-scoped loan that expires, and on macOS the file may be on a
    /// volume they are about to eject. Copying makes the map keep working
    /// after the source disappears, which is the entire point of offline.
    func importMBTiles(from url: URL) {
        cancel()
        task = Task { [weak self] in
            guard let self else { return }
            state = .importing

            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let source = try MapTileStore(url: url)
                let stats = try source.statistics()
                guard stats.tileCount > 0 else {
                    state = .failed("That file contains no map tiles.")
                    return
                }
                // A vector .mbtiles holds compressed geometry, not images.
                // MapKit cannot draw it, and importing it anyway produces a
                // store full of tiles that render as nothing — an offline map
                // that looks stored and is blank in the field, which is the
                // worst possible outcome. Refuse with an explanation instead.
                if let format = try source.metadata("format"),
                   MapTileStore.vectorFormats.contains(format.lowercased()) {
                    state = .failed("That is a vector tile file (format: \(format)). AXTerm draws raster tiles \u{2014} PNG or JPEG images \u{2014} and cannot render vector tiles. Look for a raster .mbtiles, or download a region from USGS instead.")
                    return
                }
                try copyTiles(from: source)
                if let attribution = try source.metadata("attribution") {
                    try store.setMetadata(attribution, for: "attribution")
                }
                try store.setMetadata(MapTileSource.imported.id, for: "axterm_source")
                let after = try store.statistics()
                state = .finished(tiles: stats.tileCount, bytes: after.byteSize)
            } catch {
                state = .failed("Could not read that file: \(error.localizedDescription)")
            }
        }
    }

    /// Copies zoom level by zoom level so an interrupted import still leaves
    /// a coherent map rather than a partial one level.
    private func copyTiles(from source: MapTileStore) throws {
        let stats = try source.statistics()
        guard let minZoom = stats.minimumZoom, let maxZoom = stats.maximumZoom else { return }
        for z in minZoom...maxZoom {
            if Task.isCancelled { return }
            try source.forEachTile(atZoom: z) { batch in
                try store.store(batch)
            }
        }
    }
}

// MARK: - Support

extension MapTileStore {
    /// Streams a zoom level's tiles in batches, so importing a multi-gigabyte
    /// file does not load it into memory.
    func forEachTile(atZoom zoom: Int, batchSize: Int = 512,
                     body: ([(z: Int, x: Int, y: Int, data: Data)]) throws -> Void) throws {
        var offset = 0
        while true {
            let batch = try rows(atZoom: zoom, limit: batchSize, offset: offset)
            if batch.isEmpty { return }
            try body(batch)
            offset += batch.count
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
