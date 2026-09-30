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
    /// True when the layer draws only from what its family's radios collect,
    /// so it can never show anything on a station where no radio can carry
    /// that family. It is left out of the rows there instead of sitting as a
    /// switch that does nothing, and its stored value is kept for when such
    /// a radio is added. See `RadioTrafficClassifier.possibleFamilies`.
    var needsCarrier = false
    /// What it reads when the operator has never touched it, so a summary is
    /// right on a fresh install rather than reporting everything off. Taken
    /// from `MapLayerDefaults` rather than restated, so this cannot drift
    /// from what the switch itself defaults to.
    var defaultOn: Bool { MapLayerDefaults.byKey[storageKey] ?? false }
}

nonisolated enum MapLayerCatalog {

    static let all: [MapLayer] = [
        // APRS: what a beaconing network draws.
        MapLayer(title: "Transmitted Positions", storageKey: "stations.preferTransmittedPosition",
                 family: .aprs),
        MapLayer(title: "Movement Trails", storageKey: "stations.showsTracks",
                 family: .aprs),
        MapLayer(title: "Weather Field", storageKey: "stations.showsWeatherField",
                 family: .aprs),
        MapLayer(title: "APRS Coverage Rings", storageKey: "stations.showsAPRSCoverageRing",
                 family: .aprs, needsCarrier: true),
        MapLayer(title: "Objects & Hazards", storageKey: "stations.showsObjects",
                 family: .aprs),

        // AX.25: what a connected-mode network draws.
        // Built from answers to our own connects and from stations heard
        // direct on packet radios. A radio on an APRS channel never opens a
        // session and never counts toward it.
        MapLayer(title: "Packet Coverage Rings", storageKey: "stations.showsCoverageRing",
                 family: .ax25, needsCarrier: true),
        // Digipeated APRS paths are observed paths too, so this one stays on
        // an APRS-only station.
        MapLayer(title: "Observed Paths", storageKey: "stations.showsPaths",
                 family: .ax25),
        MapLayer(title: "Predicted Paths", storageKey: "stations.showsPredictedPaths",
                 family: .ax25),
        MapLayer(title: "Node Directory", storageKey: "stations.showsDirectoryNodes",
                 family: .ax25),

        // Neither: the map itself.
        MapLayer(title: "Cluster Markers", storageKey: "stations.clustersStations",
                 family: nil),
        MapLayer(title: "Hide Distant Stations", storageKey: "stations.hidesDistantStations",
                 family: nil),
    ]

    /// The layers a scope draws, in the order the rows appear, leaving out
    /// any that need a carrier outside `possible`.
    static func layers(in scope: MapLayerScope,
                       possible: Set<RadioTrafficFamily> = Set(RadioTrafficFamily.allCases))
        -> [MapLayer] {
        all.filter { scope.includes($0.family) && isOffered($0, possible: possible) }
    }

    /// Whether a layer's switch is shown when only `possible` can be carried.
    static func isOffered(_ layer: MapLayer, possible: Set<RadioTrafficFamily>) -> Bool {
        guard layer.needsCarrier, let family = layer.family else { return true }
        return possible.contains(family)
    }

    /// `isOffered` by the key the switch binds to. A key not in the catalog
    /// is always offered.
    static func isOffered(storageKey: String, possible: Set<RadioTrafficFamily>) -> Bool {
        guard let layer = all.first(where: { $0.storageKey == storageKey }) else { return true }
        return isOffered(layer, possible: possible)
    }

    /// How many of a scope's layers are switched on, and how many there are.
    static func summary(in scope: MapLayerScope,
                        possible: Set<RadioTrafficFamily> = Set(RadioTrafficFamily.allCases),
                        defaults: UserDefaults = .standard) -> (on: Int, total: Int) {
        let layers = layers(in: scope, possible: possible)
        let on = layers.count { layer in
            defaults.object(forKey: layer.storageKey) as? Bool ?? layer.defaultOn
        }
        return (on, layers.count)
    }

    /// The one-line state of a collapsed group.
    static func summaryText(in scope: MapLayerScope,
                            possible: Set<RadioTrafficFamily> = Set(RadioTrafficFamily.allCases),
                            defaults: UserDefaults = .standard) -> String {
        let counts = summary(in: scope, possible: possible, defaults: defaults)
        guard counts.total > 0 else { return "No layers" }
        // "3 of 5 on" rather than the names: a fixed shape the eye can read
        // without parsing, and it does not change width as layers are toggled.
        return "\(counts.on) of \(counts.total) on"
    }
}
