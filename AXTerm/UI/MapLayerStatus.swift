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

    /// "3 stations · lapse rate fitted from them", or nil when too few
    /// weather stations have been heard to infer a field at all. Nil also
    /// disables the switch: a layer that cannot draw anything should say why
    /// rather than sit there looking broken.
    @Published var weatherFieldCaption: String?

    /// Which field parameters have enough stations reporting to be drawn.
    /// The picker offers only these: a humidity field needs two hygrometers,
    /// which is a different question from whether a weather station was heard
    /// at all.
    @Published var availableWeatherParameters: Set<APRSWeatherField.Parameter> = []

    /// "2 hazards · 5 objects", or nil when nothing has been placed. Hazards
    /// are counted separately because they are the reason to look.
    @Published var objectCaption: String?

    /// Why the weather field cannot be drawn, when it cannot. A greyed-out
    /// switch with no explanation is indistinguishable from a broken one.
    @Published var weatherFieldUnavailableReason: String?

    /// How many placed stations the fall-off setting is holding back.
    @Published var falloffHiddenCount = 0

    /// What the movement-trail layer is drawing, or why it is drawing nothing.
    @Published var trackCaption: String?
}
