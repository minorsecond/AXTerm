import Foundation

/// What each map layer reads before the operator has touched it.
///
/// The switches live in the sidebar and the map reads the same keys, so each
/// default was written out twice in two files with nothing keeping them in
/// step; the summary on a collapsed group made it three. Two copies that
/// disagree put the switch in one position and the map in the other, and the
/// operator has to toggle it twice to find out which one was lying.
nonisolated enum MapLayerDefaults {

    static let preferTransmittedPosition = true
    static let showsTracks = true
    /// Every rover's trail rather than only the selected station's. What the
    /// rest of APRS does, and a map that drew none until something was
    /// selected read as broken rather than as a setting (2026-09-17).
    static let showsAllTracks = true
    static let showsWeatherField = false
    static let showsObjects = true
    static let showsAPRSCoverageRing = true
    static let showsCoverageRing = true
    static let showsPaths = false
    static let showsPredictedPaths = false
    static let showsDirectoryNodes = false
    static let clustersStations = true
    static let hidesDistantStations = false

    static let showsTypeDigipeater = true
    static let showsTypeWeather = true
    static let showsTypeVehicle = true
    static let showsTypeFixed = true

    static let falloffMinutes = 0
    static let trackWindowMinutes = 60

    /// The switchable layers by storage key, for anything that reads a
    /// default by name rather than by property — the collapsed summary does,
    /// and inventing one there would misreport what the group is hiding.
    static let byKey: [String: Bool] = [
        "stations.preferTransmittedPosition": preferTransmittedPosition,
        "stations.showsTracks": showsTracks,
        "stations.showsAllTracks": showsAllTracks,
        "stations.showsWeatherField": showsWeatherField,
        "stations.showsObjects": showsObjects,
        "stations.showsAPRSCoverageRing": showsAPRSCoverageRing,
        "stations.showsCoverageRing": showsCoverageRing,
        "stations.showsPaths": showsPaths,
        "stations.showsPredictedPaths": showsPredictedPaths,
        "stations.showsDirectoryNodes": showsDirectoryNodes,
        "stations.clustersStations": clustersStations,
        "stations.hidesDistantStations": hidesDistantStations,
        "stations.showsTypeDigipeater": showsTypeDigipeater,
        "stations.showsTypeWeather": showsTypeWeather,
        "stations.showsTypeVehicle": showsTypeVehicle,
        "stations.showsTypeFixed": showsTypeFixed,
    ]
}
