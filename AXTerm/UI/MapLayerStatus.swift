import Combine
import Foundation

/// What the sidebar needs to know about the map's layers, published by the
/// map itself.
///
/// The captions and the terrain gate are computed from the map's own caches
/// — the entries it placed, the terrain it has stored, the forecast it ran.
/// The sidebar cannot see any of that, and recomputing it there would run
/// counts over every heard station on every sidebar render.
///
/// So the map pushes, and only when its inputs actually change. Nothing here
/// is a control: turning a layer on still goes through the `@AppStorage` key
/// both sides read.
@MainActor
final class MapLayerStatus: ObservableObject {

    /// Whether any terrain is stored. Predicted paths need it, and a toggle
    /// that can be switched on with nothing behind it draws nothing — which
    /// is the "enabled but invisible" report that layer collected twice.
    @Published var hasTerrain = false

    /// What the terrain forecast found, or how far off it was. Nil when
    /// there is nothing to say.
    ///
    /// "Nothing to draw" is a very common honest answer here, and a map that
    /// then draws nothing is indistinguishable from a broken feature.
    @Published var forecastSummary: String?

    /// How much of the node directory is actually on the map. Stated because
    /// "enabled but invisible" was reported against this layer too: most of
    /// a harvested directory has no position to draw at.
    @Published var directoryCaption: String?

    /// How many stations the distance filter is holding back. Zero hides the
    /// row's caption rather than saying "0 hidden".
    @Published var distantCount = 0
}
