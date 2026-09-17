import Foundation

/// The switchable map layers, as something other than rows.
///
/// The sidebar collapses each radio's layers to one line, and a collapsed
/// group has to say what it is hiding or it is worse than the long list it
/// replaced: the whole reason these left a toolbar menu was that you could
/// not see what was on without opening it. Counting them needs the layers as
/// data rather than as views, which is what this is.
///
/// It does not draw anything and it is not the source of the rows. Keep it
/// beside them: a layer added to `MapLayerToggles` and not added here is
/// missing from the summary, which is what `MapLayerCatalogTests` is for.
nonisolated struct MapLayer: Hashable, Sendable {
    let title: String
    /// The `@AppStorage` key the row binds to.
    let storageKey: String
    /// The traffic family this layer means anything for, or nil when it
    /// applies to the map as a whole.
    let family: RadioTrafficFamily?
    /// What it reads when the operator has never touched it, so a summary is
    /// right on a fresh install rather than reporting everything off.
    let defaultOn: Bool
}

nonisolated enum MapLayerCatalog {

    static let all: [MapLayer] = [
        // APRS: what a beaconing network draws.
        MapLayer(title: "Transmitted Positions", storageKey: "stations.preferTransmittedPosition",
                 family: .aprs, defaultOn: true),
        MapLayer(title: "Movement Trails", storageKey: "stations.showsTracks",
                 family: .aprs, defaultOn: true),
        MapLayer(title: "Weather Field", storageKey: "stations.showsWeatherField",
                 family: .aprs, defaultOn: false),
        MapLayer(title: "Coverage Rings", storageKey: "stations.showsAPRSCoverageRing",
                 family: .aprs, defaultOn: true),
        MapLayer(title: "Objects & Hazards", storageKey: "stations.showsObjects",
                 family: .aprs, defaultOn: true),

        // AX.25: what a connected-mode network draws.
        MapLayer(title: "Coverage Rings", storageKey: "stations.showsCoverageRing",
                 family: .ax25, defaultOn: true),
        MapLayer(title: "Observed Paths", storageKey: "stations.showsPaths",
                 family: .ax25, defaultOn: false),
        MapLayer(title: "Predicted Paths", storageKey: "stations.showsPredictedPaths",
                 family: .ax25, defaultOn: false),
        MapLayer(title: "Node Directory", storageKey: "stations.showsDirectoryNodes",
                 family: .ax25, defaultOn: false),

        // Neither: the map itself.
        MapLayer(title: "Cluster Markers", storageKey: "stations.clustersStations",
                 family: nil, defaultOn: true),
        MapLayer(title: "Hide Distant Stations", storageKey: "stations.hidesDistantStations",
                 family: nil, defaultOn: false),
    ]

    /// The layers a scope draws, in the order the rows appear.
    static func layers(in scope: MapLayerScope) -> [MapLayer] {
        all.filter { scope.includes($0.family) }
    }

    /// How many of a scope's layers are switched on, and how many there are.
    static func summary(in scope: MapLayerScope,
                        defaults: UserDefaults = .standard) -> (on: Int, total: Int) {
        let layers = layers(in: scope)
        let on = layers.count { layer in
            defaults.object(forKey: layer.storageKey) as? Bool ?? layer.defaultOn
        }
        return (on, layers.count)
    }

    /// The one-line state of a collapsed group.
    static func summaryText(in scope: MapLayerScope,
                            defaults: UserDefaults = .standard) -> String {
        let counts = summary(in: scope, defaults: defaults)
        guard counts.total > 0 else { return "No layers" }
        // "3 of 5 on" rather than the names: a fixed shape the eye can read
        // without parsing, and it does not change width as layers are toggled.
        return "\(counts.on) of \(counts.total) on"
    }
}
