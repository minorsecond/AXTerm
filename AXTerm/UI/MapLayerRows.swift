import SwiftUI

/// What the map draws, as a section of the main sidebar.
///
/// These toggles lived in a toolbar menu, which meant every change to what
/// the page draws cost opening a menu, and the current state was invisible
/// until you did. They are the map's navigation, so they belong where the
/// other pages keep theirs.
///
/// The same `@AppStorage` keys the map itself reads, so the two stay in step
/// without anything being passed between them.
///
/// Predicted Paths is deliberately not here. It is gated on downloaded
/// terrain and carries a forecast summary when it is on, and both of those
/// live on the map's own `ElevationStorage`. A toggle here that could be
/// switched on with no terrain behind it would draw nothing — the exact
/// "enabled but invisible" complaint that layer already collected twice.
struct MapLayerRows: View {

    @AppStorage("stations.showsPaths") private var showsPaths = false
    @AppStorage("stations.showsDirectoryNodes") private var showsDirectoryNodes = false
    @AppStorage("stations.showsCoverageRing") private var showsCoverageRing = true
    @AppStorage("stations.hidesDistantStations") private var hidesDistantStations = false
    @AppStorage("stations.showsList") private var showsList = true

    var body: some View {
        Section("Layers") {
            Toggle(isOn: $showsPaths) {
                Label("Observed Paths", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .help("Paths observed between stations. Colour is evidence: green completed a connect end to end, blue arrived through a digipeater, teal was heard direct, grey dashed is inferred from a shared digipeater, red means connect attempts went unanswered.")

            Toggle(isOn: $showsDirectoryNodes) {
                Label("Node Directory", systemImage: "list.bullet.indent")
            }
            .help("Every station the network has claimed reachable that can be placed from cached positions. Dashed when the position is the operator's address rather than the node's own. Nothing is looked up online for this layer.")

            Toggle(isOn: $showsCoverageRing) {
                Label("Coverage Rings", systemImage: "circle.dashed")
            }
            .help("Rings drawn from the stations that answered you directly \u{2014} a UA, DM or FRMR to your frames proves they decoded you. Measurements, not a propagation model.")

            Toggle(isOn: $hidesDistantStations) {
                Label("Hide Distant Stations", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .help("Sets aside stations too far away to have arrived by radio. One internet-bridged station on the far coast stretches the zoom until every local station is a single cluster.")

            Toggle(isOn: $showsList) {
                Label("Station List", systemImage: "sidebar.right")
            }
            .help("The list of stations beside the map.")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
