import Foundation
import GRDB
import MapKit

/// A real offline basemap: a local store of map tiles that MapKit draws from
/// with no network at all.
///
/// The existing `OfflineMapSnapshot` captures one PNG of one region at one
/// zoom. That is a photograph of a map, not a map — it cannot be panned past
/// its edge or zoomed past its scale, which is exactly what an operator does
/// when they are working out whether a hill is in the way. This stores tiles
/// instead, so the map behaves like a map while completely offline.
///
/// **MBTiles-compatible on purpose.** The schema is the MBTiles 1.3 spec, so
/// a region downloaded here can be read by other tools, and — far more
/// usefully — an `.mbtiles` file the operator downloaded from anywhere can be
/// imported and used directly. That import path is the one that is
/// unambiguously allowed by every provider's terms, and it is the one that
/// scales to a whole state.
nonisolated final class MapTileStore: @unchecked Sendable {

    /// `format` metadata values that mean vector geometry rather than images.
    ///
    /// MapKit renders raster tiles only. A vector file imports "successfully"
    /// and then draws nothing, which is worse than a refusal: the operator
    /// believes they have an offline map until they are somewhere without a
    /// signal.
    static let vectorFormats: Set<String> = ["pbf", "mvt", "application/x-protobuf"]

    /// MBTiles stores rows bottom-up (TMS); MapKit asks top-down (XYZ).
    ///
    /// Getting this backwards produces a map that looks plausible — tiles
    /// render, at the right zoom, in the right places — but is mirrored
    /// north-to-south. On a bearing-and-range tool that is not a cosmetic
    /// bug: it puts the ridge on the wrong side of the operator.
    static func tmsRow(y: Int, zoom: Int) -> Int {
        (1 << zoom) - 1 - y
    }

    private let dbQueue: DatabaseQueue
    let url: URL

    /// Opens or creates a tile store.
    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var config = Configuration()
        // Tiles are immutable once written and read far more than written, so
        // the extra durability of full synchronous writes buys nothing here
        // and costs a lot on a download of tens of thousands of tiles.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try migrate()
    }

    private func migrate() throws {
        try dbQueue.write { db in
            // The MBTiles 1.3 schema, verbatim, so other tools can read this
            // file and this can read theirs.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS tiles (
                    zoom_level INTEGER NOT NULL,
                    tile_column INTEGER NOT NULL,
                    tile_row INTEGER NOT NULL,
                    tile_data BLOB NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS tile_index
                ON tiles (zoom_level, tile_column, tile_row)
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS metadata (
                    name TEXT PRIMARY KEY,
                    value TEXT
                )
                """)
        }
    }

    // MARK: - Tiles

    func tile(z: Int, x: Int, y: Int) throws -> Data? {
        try dbQueue.read { db in
            try Data.fetchOne(db, sql: """
                SELECT tile_data FROM tiles
                WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?
                """, arguments: [z, x, Self.tmsRow(y: y, zoom: z)])
        }
    }

    func hasTile(z: Int, x: Int, y: Int) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT 1 FROM tiles
                WHERE zoom_level = ? AND tile_column = ? AND tile_row = ? LIMIT 1
                """, arguments: [z, x, Self.tmsRow(y: y, zoom: z)]) ?? false
        }
    }

    /// Writes a batch in one transaction.
    ///
    /// Batched because a region download is tens of thousands of small rows
    /// and one transaction each would spend all its time in fsync
    /// (CLAUDE.md §12: batched DB writes).
    func store(_ tiles: [(z: Int, x: Int, y: Int, data: Data)]) throws {
        guard !tiles.isEmpty else { return }
        try dbQueue.write { db in
            for tile in tiles {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO tiles (zoom_level, tile_column, tile_row, tile_data)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [tile.z, tile.x, Self.tmsRow(y: tile.y, zoom: tile.z), tile.data])
            }
        }
    }

    // MARK: - Metadata

    func setMetadata(_ value: String, for key: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO metadata (name, value) VALUES (?, ?)",
                           arguments: [key, value])
        }
    }

    func metadata(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE name = ?",
                                arguments: [key])
        }
    }

    /// What the store actually holds, for the storage panel.
    struct Statistics: Equatable, Sendable {
        var tileCount: Int
        var byteSize: Int
        var minimumZoom: Int?
        var maximumZoom: Int?

        /// Human-readable size. Offline map storage is the one thing in this
        /// app that can consume gigabytes, so it is always shown.
        var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
        }
    }

    func statistics() throws -> Statistics {
        try dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tiles") ?? 0
            let bytes = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(LENGTH(tile_data)), 0) FROM tiles") ?? 0
            let minZoom = try Int.fetchOne(db, sql: "SELECT MIN(zoom_level) FROM tiles")
            let maxZoom = try Int.fetchOne(db, sql: "SELECT MAX(zoom_level) FROM tiles")
            return Statistics(tileCount: count, byteSize: bytes,
                              minimumZoom: minZoom, maximumZoom: maxZoom)
        }
    }

    /// One page of a zoom level's tiles, in stored (TMS) order.
    ///
    /// Used to stream an import: reading a multi-gigabyte `.mbtiles` file
    /// into memory to copy it would defeat the purpose.
    func rows(atZoom zoom: Int, limit: Int, offset: Int) throws
        -> [(z: Int, x: Int, y: Int, data: Data)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT tile_column, tile_row, tile_data FROM tiles
                WHERE zoom_level = ?
                ORDER BY tile_column, tile_row
                LIMIT ? OFFSET ?
                """, arguments: [zoom, limit, offset])
            return rows.map { row in
                let column: Int = row["tile_column"]
                let tmsRow: Int = row["tile_row"]
                let data: Data = row["tile_data"]
                // Back to XYZ, since `store(_:)` converts to TMS on the way in.
                return (z: zoom, x: column, y: Self.tmsRow(y: tmsRow, zoom: zoom), data: data)
            }
        }
    }

    /// Deletes every tile, keeping the file and its metadata.
    func removeAllTiles() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tiles")
        }
        // Reclaim the space rather than leaving a multi-gigabyte file full of
        // free pages — the operator deleted it to get the space back.
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }
}

// MARK: - Tile geometry

/// Slippy-map tile arithmetic (the Web Mercator scheme every raster provider
/// and MapKit's own `MKTileOverlay` use).
nonisolated enum MapTileMath {

    /// Tile containing a coordinate at a zoom level.
    static func tile(latitude: Double, longitude: Double, zoom: Int) -> (x: Int, y: Int) {
        let n = Double(1 << zoom)
        let clampedLat = min(max(latitude, -85.05112878), 85.05112878)
        let latRad = clampedLat * .pi / 180
        let x = Int(((longitude + 180) / 360 * n).rounded(.down))
        let y = Int(((1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n).rounded(.down))
        let maximum = (1 << zoom) - 1
        return (min(max(x, 0), maximum), min(max(y, 0), maximum))
    }

    /// Every tile covering a region across a zoom range.
    ///
    /// Returned in zoom order, coarsest first, so a download that is
    /// interrupted still leaves a usable — if blurry — map rather than a
    /// sharp patch and nothing around it.
    static func tiles(covering region: MKCoordinateRegion,
                      zoomRange: ClosedRange<Int>) -> [(z: Int, x: Int, y: Int)] {
        let north = region.center.latitude + region.span.latitudeDelta / 2
        let south = region.center.latitude - region.span.latitudeDelta / 2
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let east = region.center.longitude + region.span.longitudeDelta / 2

        var result: [(z: Int, x: Int, y: Int)] = []
        for z in zoomRange {
            let topLeft = tile(latitude: north, longitude: west, zoom: z)
            let bottomRight = tile(latitude: south, longitude: east, zoom: z)
            guard topLeft.x <= bottomRight.x, topLeft.y <= bottomRight.y else { continue }
            for x in topLeft.x...bottomRight.x {
                for y in topLeft.y...bottomRight.y {
                    result.append((z, x, y))
                }
            }
        }
        return result
    }

    /// How many tiles a region would need — the number to show an operator
    /// *before* they start a download, not after.
    static func tileCount(covering region: MKCoordinateRegion,
                          zoomRange: ClosedRange<Int>) -> Int {
        tiles(covering: region, zoomRange: zoomRange).count
    }

    /// Rough download size. Raster tiles average 15–25 KB; 20 KB is the
    /// middle of that and is stated as an estimate, never as a promise.
    static let averageTileBytes = 20 * 1024

    static func estimatedBytes(tileCount: Int) -> Int {
        tileCount * averageTileBytes
    }
}
