import CryptoKit
import Foundation
import GRDB

/// One stored version of a hazard: the feature as first seen, and when it
/// was last seen again unchanged.
struct HazardHistoryRow: Equatable, Sendable {
    var feature: HazardFeature
    var lastSeen: Date
}

/// Every version of every hazard fetched or received, append-only, in the
/// station database (Docs/HazardLayers.md §8). The live layers hold the
/// latest copy; this holds all of them, for a time slider and after-action
/// exports.
final class SQLiteHazardHistoryStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Adds what is new and touches what is not. A version is new when its
    /// content differs: a fire perimeter is kept when its shape changes, not
    /// on every fetch.
    func record(_ features: [HazardFeature]) throws {
        try dbQueue.write { db in
            for feature in features {
                let hash = Self.contentHash(feature)
                let seen = feature.fetchedAt.timeIntervalSince1970
                if try Row.fetchOne(db, sql: "SELECT 1 FROM hazard_history WHERE featureID = ? AND contentHash = ?",
                                    arguments: [feature.id, hash]) != nil {
                    try db.execute(sql: """
                        UPDATE hazard_history SET lastSeen = MAX(lastSeen, ?)
                        WHERE featureID = ? AND contentHash = ?
                        """, arguments: [seen, feature.id, hash])
                    continue
                }
                // The same alert first recorded before its zones' outlines
                // loaded: its shape fills in, rather than counting as a new
                // version. That row's hash is this feature's without a shape.
                if feature.geometry != nil {
                    var shapeless = feature
                    shapeless.geometry = nil
                    let shapelessHash = Self.contentHash(shapeless)
                    if try Row.fetchOne(db, sql: """
                        SELECT 1 FROM hazard_history
                        WHERE featureID = ? AND contentHash = ? AND geometry IS NULL
                        """, arguments: [feature.id, shapelessHash]) != nil {
                        try db.execute(sql: """
                            UPDATE hazard_history SET contentHash = ?, geometry = ?, lastSeen = MAX(lastSeen, ?)
                            WHERE featureID = ? AND contentHash = ?
                            """, arguments: [hash, feature.geometry.map(HazardGeometryCoding.encode), seen,
                                             feature.id, shapelessHash])
                        continue
                    }
                }
                try db.execute(sql: """
                    INSERT INTO hazard_history (featureID, contentHash, kind, event, headline, severity,
                        source, issued, expires, firstSeen, lastSeen, geometry, zoneIDs, properties, replaces)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        feature.id, hash, feature.kind.rawValue, feature.event, feature.headline,
                        feature.severity, feature.source, feature.issued?.timeIntervalSince1970,
                        feature.expires?.timeIntervalSince1970, seen, seen,
                        feature.geometry.map(HazardGeometryCoding.encode),
                        Self.json(feature.zoneIDs), Self.json(feature.properties),
                        Self.json(Self.replacedIDs(feature)),
                    ])
            }
        }
    }

    /// Every stored version of one hazard, oldest first.
    func versions(of id: String) throws -> [HazardHistoryRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM hazard_history WHERE featureID = ? ORDER BY firstSeen",
                             arguments: [id]).map(Self.row)
        }
    }

    /// What was in effect at a moment: begun (issued, or first seen when the
    /// source gives no issue time) and not expired, minus anything an NWS
    /// update issued by then replaces, taking each hazard's latest version.
    func inEffect(at moment: Date) throws -> [HazardFeature] {
        let t = moment.timeIntervalSince1970
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM hazard_history
                WHERE COALESCE(issued, firstSeen) <= ?
                ORDER BY COALESCE(issued, firstSeen), firstSeen
                """, arguments: [t])
        }
        var replaced = Set<String>()
        var latest: [String: HazardFeature] = [:]
        var order: [String] = []
        for row in rows {
            let ids: [String] = Self.decode(row["replaces"]) ?? []
            replaced.formUnion(ids)
            let feature = Self.row(row).feature
            if latest[feature.id] == nil { order.append(feature.id) }
            latest[feature.id] = feature
        }
        return order.compactMap { latest[$0] }
            .filter { !replaced.contains($0.id) && !$0.isExpired(at: moment) }
    }

    // MARK: - Encoding

    /// The NWS `references` list: the messages an update or cancellation
    /// replaces.
    static func replacedIDs(_ feature: HazardFeature) -> [String] {
        guard let json = feature.properties["references"]?.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else { return [] }
        return list.compactMap { $0["identifier"] as? String }
    }

    static func contentHash(_ feature: HazardFeature) -> String {
        let parts: [String] = [
            feature.kind.rawValue, feature.event, feature.headline ?? "", feature.severity ?? "",
            feature.source, feature.issued.map { "\($0.timeIntervalSince1970)" } ?? "",
            feature.expires.map { "\($0.timeIntervalSince1970)" } ?? "",
            feature.geometry.map(HazardGeometryCoding.encode) ?? "",
            json(feature.zoneIDs), json(feature.properties),
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func row(_ row: Row) -> HazardHistoryRow {
        let kind = HazardFeature.Kind(rawValue: row["kind"]) ?? .statement
        var feature = HazardFeature(id: row["featureID"], kind: kind, event: row["event"], source: row["source"],
                                    fetchedAt: Date(timeIntervalSince1970: row["firstSeen"]))
        feature.headline = row["headline"]
        feature.severity = row["severity"]
        feature.issued = (row["issued"] as Double?).map(Date.init(timeIntervalSince1970:))
        feature.expires = (row["expires"] as Double?).map(Date.init(timeIntervalSince1970:))
        feature.geometry = (row["geometry"] as String?).flatMap(HazardGeometryCoding.decode)
        feature.zoneIDs = decode(row["zoneIDs"]) ?? []
        feature.properties = decode(row["properties"]) ?? [:]
        return HazardHistoryRow(feature: feature, lastSeen: Date(timeIntervalSince1970: row["lastSeen"]))
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func decode<T: Decodable>(_ text: String?) -> T? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// A hazard's geometry as GeoJSON text, [longitude, latitude].
nonisolated enum HazardGeometryCoding {
    static func encode(_ geometry: HazardFeature.Geometry) -> String {
        let object: [String: Any]
        switch geometry {
        case .point(let point):
            object = ["type": "Point", "coordinates": [point.longitude, point.latitude]]
        case .polygons(let polygons):
            object = ["type": "MultiPolygon",
                      "coordinates": polygons.map { $0.map { $0.map { [$0.longitude, $0.latitude] } } }]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decode(_ text: String) -> HazardFeature.Geometry? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return NWSAlertFeed.geometry(from: object)
    }
}
