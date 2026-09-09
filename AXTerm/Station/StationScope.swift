import Foundation

/// A polar plot of stations around this one: what is out there, which
/// way, how far, and how well it works.
///
/// Deliberately **not** a road map. A base map needs tiles, tiles need
/// the network, and the network is the thing this app exists to survive
/// the loss of. For "can I reach that station", bearing, distance and
/// measured link quality *are* the information — roads and terrain are
/// not. So this is a radar scope, computed from coordinates the station
/// already holds, and it works with everything else down.
///
/// The model carries no colours, no fonts and no view types, so anything
/// with positions can build one — RMS gateways today, NET/ROM neighbours
/// or heard stations tomorrow — and get the same rendering for free.
nonisolated struct StationScope: Equatable, Sendable {

    /// How well a site works, in the abstract. The view picks colours;
    /// the model stays presentation-free.
    enum Signal: Int, Comparable, Sendable {
        case unknown
        case poor
        case fair
        case good

        static func < (lhs: Signal, rhs: Signal) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Site: Equatable, Sendable, Identifiable {
        var id: String
        var label: String
        /// Kilometres from the observer.
        var kilometres: Double
        /// True bearing from the observer, 0 = north, clockwise.
        var bearingDegrees: Double
        var signal: Signal
        /// One line for the label, e.g. "145.050 · 1200 bd".
        var subtitle: String
        /// Full explanation for the tooltip.
        var detail: String
        /// When this station was last heard, for the map's "just transmitted"
        /// marking. Distinct from `signal`/`isStale`, which grade recency over
        /// minutes and hours; this answers "is it on the air right now".
        var lastHeard: Date? = nil
        /// Drawn faded — known to exist, but not recently confirmed.
        var isStale: Bool
        /// The position is a lead rather than a location — drawn hollow
        /// so it can never be mistaken for a fix.
        var isApproximate: Bool = false
        /// A NET/ROM node or directory entry rather than a heard station —
        /// drawn in its own colour and glyph so infrastructure reads apart
        /// from traffic.
        var isNode: Bool = false
        /// The APRS symbol the station beaconed, when it is placed at its own
        /// transmitted fix. Carried on the Site (not a side table) so a
        /// SwiftUI `Map` annotation actually rebuilds when the symbol arrives.
        var aprsSymbol: APRSMapSymbol? = nil
        /// One current reading drawn beside the callsign — a weather
        /// station's temperature. Already formatted, because the Site is what
        /// both map renderers read and neither should be converting units.
        var weatherBadge: String? = nil
        /// The whole reading, for the card, which lays it out rather than
        /// printing it. `detail` deliberately leaves it out so the card does
        /// not say the same thing twice.
        var weather: APRSWeather? = nil
        var weatherHeard: Date? = nil
        /// This station's readings over time, for the barometric tendency.
        var weatherHistory: [Station.WeatherSample] = []
        /// Non-weather sensors this station reports, already labelled and
        /// calibrated as far as the station has said how.
        var telemetry: [APRSTelemetry.Reading] = []
        var telemetryTitle: String?
        /// Whether a connected-mode call to this site could go anywhere.
        ///
        /// False for a station heard only as APRS beacons and for an object,
        /// which is not a station at all. APRS is connectionless: a weather
        /// station or a tracker runs no service to answer a SABM, so offering
        /// Connect there transmits call attempts nobody will ever answer and
        /// retries them to the limit.
        var supportsConnect: Bool = true
        /// Whether an APRS message or position request could reach it. False
        /// for objects: a fire has no radio.
        var supportsAPRSContact: Bool = true
        /// Hover text: the detail plus the weather in words. A tooltip has no
        /// layout, so the reading has to arrive as prose there.
        var weatherLines: [String] = []

        /// What hovering the marker shows — everything the card shows, in
        /// text.
        var tooltip: String {
            var text = detail
            if !weatherLines.isEmpty { text += "\n" + weatherLines.joined(separator: "\n") }
            if !telemetry.isEmpty {
                text += "\n" + (telemetryTitle ?? "Telemetry") + ": "
                    + telemetry.map { ($0.name.map { n in n + " " } ?? "") + $0.text }
                        .joined(separator: ", ")
            }
            return text
        }

        var compassPoint: String { GreatCircle.compassPoint(bearingDegrees) }

        /// Position on a unit scope: x east, y **south** (screen
        /// coordinates, y down), both in −1…1 at the outer ring.
        func unitPoint(maxRange: Double) -> (x: Double, y: Double) {
            guard maxRange > 0 else { return (0, 0) }
            let radius = min(1, kilometres / maxRange)
            let radians = bearingDegrees * .pi / 180
            return (x: radius * sin(radians), y: -radius * cos(radians))
        }
    }

    /// Where the observer is, for the centre label.
    var observerLabel: String
    var sites: [Site]
    /// Outer edge of the scope, in kilometres.
    var maxRange: Double
    /// Ring distances to draw, inside `maxRange`.
    var rings: [Double]

    var isEmpty: Bool { sites.isEmpty }

    // MARK: - Building

    /// Ring steps that read well on a scope. Anything finer clutters;
    /// anything coarser wastes the plot.
    static let ringSteps: [Double] = [
        1, 2, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10_000, 20_000,
    ]

    /// Chooses an outer range that contains every site, rounded up to a
    /// ring step so the outermost ring is a round number rather than
    /// whatever the furthest station happens to be.
    static func range(covering sites: [Site]) -> Double {
        let furthest = sites.map(\.kilometres).max() ?? 0
        guard furthest > 0 else { return ringSteps[0] }
        return ringSteps.first { $0 >= furthest } ?? furthest
    }

    /// Up to three rings inside the outer edge, so the scope reads as a
    /// scale rather than a target.
    static func rings(forRange range: Double) -> [Double] {
        let candidates = ringSteps.filter { $0 < range && $0 >= range / 10 }
        guard candidates.count > 3 else { return candidates }
        // Keep the largest few — the near rings crowd the centre.
        return Array(candidates.suffix(3))
    }

    /// Builds a scope, dropping sites whose position is unknown rather
    /// than guessing one. A station plotted in the wrong place is worse
    /// than a station not plotted.
    static func build(observerLabel: String, sites: [Site]) -> StationScope {
        let sorted = sites.sorted { ($0.kilometres, $0.id) < ($1.kilometres, $1.id) }
        let range = range(covering: sorted)
        return StationScope(
            observerLabel: observerLabel,
            sites: sorted,
            maxRange: range,
            rings: rings(forRange: range))
    }

    /// What a caller hands in before range and bearing are known: a Site
    /// without the two fields this type computes.
    ///
    /// A struct with defaults rather than a tuple. As a tuple this had grown
    /// to fourteen positional elements, and every new field broke every call
    /// site and every test that built one — including ones that could not
    /// care less about the field being added.
    struct SiteDraft {
        var id: String
        var label: String
        var position: GreatCircle.Point?
        var signal: Signal
        var subtitle: String = ""
        var detail: String = ""
        var lastHeard: Date? = nil
        var isStale: Bool = false
        var isApproximate: Bool = false
        var isNode: Bool = false
        var aprsSymbol: APRSMapSymbol? = nil
        var weatherBadge: String? = nil
        var weather: APRSWeather? = nil
        var weatherHeard: Date? = nil
        var weatherHistory: [Station.WeatherSample] = []
        var telemetry: [APRSTelemetry.Reading] = []
        var telemetryTitle: String?
        var supportsConnect: Bool = true
        var supportsAPRSContact: Bool = true
        var weatherLines: [String] = []
    }

    /// Convenience for callers that have coordinates: computes range and
    /// bearing for each, and skips any without a position.
    static func build(observerLabel: String,
                      observer: GreatCircle.Point,
                      entries: [SiteDraft]) -> StationScope {
        let sites = entries.compactMap { entry -> Site? in
            guard let position = entry.position else { return nil }
            return Site(
                id: entry.id,
                label: entry.label,
                kilometres: GreatCircle.kilometres(from: observer, to: position),
                bearingDegrees: GreatCircle.bearingDegrees(from: observer, to: position),
                signal: entry.signal,
                subtitle: entry.subtitle,
                detail: entry.detail,
                lastHeard: entry.lastHeard,
                isStale: entry.isStale,
                isApproximate: entry.isApproximate,
                isNode: entry.isNode,
                aprsSymbol: entry.aprsSymbol,
                weatherBadge: entry.weatherBadge,
                weather: entry.weather,
                weatherHeard: entry.weatherHeard,
                weatherHistory: entry.weatherHistory,
                telemetry: entry.telemetry,
                telemetryTitle: entry.telemetryTitle,
                supportsConnect: entry.supportsConnect,
                supportsAPRSContact: entry.supportsAPRSContact,
                weatherLines: entry.weatherLines)
        }
        return build(observerLabel: observerLabel, sites: sites)
    }
}
