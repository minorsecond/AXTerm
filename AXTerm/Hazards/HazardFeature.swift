import Foundation

/// One hazard on the map, whatever it came from: a warning, a fire, a storm
/// report, a quake (Docs/HazardLayers.md §3).
///
/// Every source is an internet feed, so each feature carries where it came
/// from and how old it is, and keeps everything the source returned even
/// when the UI shows a few fields.
nonisolated struct HazardFeature: Identifiable, Equatable, Sendable {

    enum Kind: String, Sendable, CaseIterable {
        case warning
        case watch
        case advisory
        /// Statements, outlooks and anything else the NWS issues.
        case statement
        case firePerimeter
        case fireIncident
        case stormReport
        case earthquake
    }

    /// GeoJSON's shapes as the map needs them. Polygons are a list of
    /// polygons, each a list of rings: the outer ring first, holes after.
    enum Geometry: Equatable, Sendable {
        case point(GreatCircle.Point)
        case polygons([[[GreatCircle.Point]]])
    }

    /// The source's own identifier.
    let id: String
    var kind: Kind
    /// The event as the source names it, e.g. "Red Flag Warning".
    var event: String
    var headline: String?
    /// The source's severity word, verbatim ("Severe", "Moderate", "Unknown").
    var severity: String?
    /// Who issued it, e.g. "NWS Boulder CO".
    var source: String
    var issued: Date?
    var expires: Date?
    /// When this receiver fetched it. The age shown beside it.
    var fetchedAt: Date
    /// Nil for a zone-based NWS product until its zones' outlines are known.
    var geometry: Geometry?
    /// NWS zone or county codes it covers, e.g. "COC007".
    var zoneIDs: [String] = []
    /// Every property the source returned, as text.
    var properties: [String: String] = [:]

    init(id: String, kind: Kind, event: String, source: String, fetchedAt: Date) {
        self.id = id
        self.kind = kind
        self.event = event
        self.source = source
        self.fetchedAt = fetchedAt
    }

    /// Past its expiry by the source's own time. No expiry given is not
    /// expired: some storm reports and incidents have none.
    func isExpired(at now: Date) -> Bool {
        guard let expires else { return false }
        return expires <= now
    }
}
