import Foundation
import GRDB

/// Stored elevation grids, so terrain analysis works with the network down.
///
/// The same argument as the basemap: a path profile computed only when there
/// is a connection is a path profile available exactly when it is least
/// needed. USGS 3DEP serves 32-bit float GeoTIFF grids with no API key, and
/// this keeps them.
///
/// Stored as raw float arrays rather than TIFFs. The TIFF wrapper is parsed
/// once on download and discarded — decoding it on every elevation lookup
/// would put an image decode inside a loop that runs a few hundred times per
/// profile.
nonisolated final class ElevationStore: @unchecked Sendable {

    /// One square degree per tile.
    ///
    /// Big enough that a typical VHF path touches one or two tiles, small
    /// enough that an operator downloading "the area around here" is not
    /// fetching a state. At the resolution below, a tile is about 4 MB.
    static let tileDegrees = 1.0

    /// Samples per side of a tile.
    ///
    /// 1024 across one degree is roughly 100 m per sample at mid-latitudes —
    /// finer than the ridges that decide a VHF path, and coarse enough that a
    /// tile stays a few megabytes. 3DEP's native 1 m data would be four
    /// orders of magnitude larger for no benefit to this question.
    static let tileSamples = 1024

    /// Marks a sample the source had no data for. NaN rather than zero or
    /// -9999: it propagates rather than quietly becoming sea level, and every
    /// comparison against it is false, so a gap cannot pass a clearance test.
    static let noDataValue = Float.nan

    private let dbQueue: DatabaseQueue
    let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS elevation (
                    tile_lat INTEGER NOT NULL,
                    tile_lon INTEGER NOT NULL,
                    samples INTEGER NOT NULL,
                    grid BLOB NOT NULL,
                    PRIMARY KEY (tile_lat, tile_lon)
                )
                """)
        }
    }

    // MARK: - Tiles

    /// Which tile a coordinate falls in. Floor, so negative longitudes land
    /// in the tile whose south-west corner is below them — the convention the
    /// rest of the arithmetic assumes.
    static func tileIndex(for point: GreatCircle.Point) -> (lat: Int, lon: Int) {
        (Int(floor(point.latitude / tileDegrees)), Int(floor(point.longitude / tileDegrees)))
    }

    /// Bounding box of a tile, as (south, west, north, east).
    static func bounds(lat: Int, lon: Int) -> (south: Double, west: Double,
                                               north: Double, east: Double) {
        let south = Double(lat) * tileDegrees
        let west = Double(lon) * tileDegrees
        return (south, west, south + tileDegrees, west + tileDegrees)
    }

    /// How many tiles are stored — the honest measure of terrain coverage,
    /// since a store that exists but is empty answers every profile with
    /// "unknown".
    func tileCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM elevation") ?? 0
        }
    }

    /// Which tiles are on disk, for drawing them.
    func storedTiles() throws -> [(lat: Int, lon: Int)] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT tile_lat, tile_lon FROM elevation ORDER BY tile_lat, tile_lon"
            ).map { (lat: $0["tile_lat"], lon: $0["tile_lon"]) }
        }
    }

    func removeAllTiles() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM elevation")
        }
        try dbQueue.vacuum()
    }

    func hasTile(lat: Int, lon: Int) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT 1 FROM elevation WHERE tile_lat = ? AND tile_lon = ? LIMIT 1
                """, arguments: [lat, lon]) ?? false
        }
    }

    func store(lat: Int, lon: Int, samples: Int, grid: [Float]) throws {
        precondition(grid.count == samples * samples, "grid is not square")
        // Encoded from here on. Tiles written before this stay readable, and
        // are re-encoded the next time they are fetched rather than in a
        // migration: a rewrite of every stored tile is a lot of I/O at launch
        // to save space the operator is not short of yet.
        let blob = (try? ElevationTileCodec.encode(grid, samples: samples))
            ?? grid.withUnsafeBufferPointer { Data(buffer: $0) }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO elevation (tile_lat, tile_lon, samples, grid)
                VALUES (?, ?, ?, ?)
                """, arguments: [lat, lon, samples, blob])
        }
    }

    func tile(lat: Int, lon: Int) throws -> (samples: Int, grid: [Float])? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT samples, grid FROM elevation WHERE tile_lat = ? AND tile_lon = ?
                """, arguments: [lat, lon]) else { return nil }
            let samples: Int = row["samples"]
            let blob: Data = row["grid"]
            // Either format. The encoded one says so in its first four bytes;
            // anything else is a raw Float32 tile from before the codec.
            if ElevationTileCodec.isEncoded(blob),
               let decoded = try? ElevationTileCodec.decode(blob) {
                return decoded
            }
            let grid = blob.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self))
            }
            return (samples, grid)
        }
    }

    struct Statistics: Equatable, Sendable {
        var tileCount: Int
        var byteSize: Int

        var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
        }
    }

    func statistics() throws -> Statistics {
        try dbQueue.read { db in
            Statistics(
                tileCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM elevation") ?? 0,
                byteSize: try Int.fetchOne(
                    db, sql: "SELECT COALESCE(SUM(LENGTH(grid)), 0) FROM elevation") ?? 0)
        }
    }

    func removeAll() throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM elevation") }
        try dbQueue.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
    }
}

// MARK: - Sampling

/// Reads elevation out of the store, interpolating between samples.
///
/// Bilinear rather than nearest-neighbour: at ~100 m spacing, nearest
/// neighbour puts visible steps in a path profile and can miss a ridge crest
/// by half a sample. The interpolation is between real measurements, so it
/// smooths without inventing terrain that is not there.
nonisolated struct StoredElevationSampler: ElevationSampling {

    private let store: ElevationStore
    /// Small cache so a profile's few hundred lookups touch the database
    /// once per tile rather than once per sample.
    private let cache: TileCache

    final class TileCache: @unchecked Sendable {
        private let lock = NSLock()
        private var tiles: [String: (samples: Int, grid: [Float])?] = [:]

        func tile(_ key: String, load: () -> (samples: Int, grid: [Float])?)
            -> (samples: Int, grid: [Float])? {
            lock.lock()
            if let cached = tiles[key] { lock.unlock(); return cached }
            lock.unlock()

            let loaded = load()
            lock.lock()
            tiles[key] = loaded
            lock.unlock()
            return loaded
        }
    }

    init(store: ElevationStore) {
        self.store = store
        self.cache = TileCache()
    }

    func elevation(at point: GreatCircle.Point) -> Double? {
        let index = ElevationStore.tileIndex(for: point)
        let key = "\(index.lat)/\(index.lon)"
        guard let tile = cache.tile(key, load: { try? store.tile(lat: index.lat, lon: index.lon) }),
              tile.samples > 1 else { return nil }

        let bounds = ElevationStore.bounds(lat: index.lat, lon: index.lon)
        // Position within the tile, 0…1. Latitude is inverted because grids
        // are stored north-row-first, the way every raster format writes them.
        let u = (point.longitude - bounds.west) / ElevationStore.tileDegrees
        let v = (bounds.north - point.latitude) / ElevationStore.tileDegrees
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }

        let last = Double(tile.samples - 1)
        let x = u * last, y = v * last
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let x1 = min(x0 + 1, tile.samples - 1), y1 = min(y0 + 1, tile.samples - 1)
        let fx = x - Double(x0), fy = y - Double(y0)

        func sample(_ column: Int, _ row: Int) -> Double? {
            let value = tile.grid[row * tile.samples + column]
            // NaN is the no-data marker, and must not be interpolated into a
            // plausible-looking number.
            return value.isFinite ? Double(value) : nil
        }

        guard let a = sample(x0, y0), let b = sample(x1, y0),
              let c = sample(x0, y1), let d = sample(x1, y1) else { return nil }

        let top = a + (b - a) * fx
        let bottom = c + (d - c) * fx
        return top + (bottom - top) * fy
    }
}
