import SwiftUI

/// What the map draws, as a section of the main sidebar.
///
/// These lived in a toolbar menu, so changing what the page drew cost
/// opening a menu and the current state was invisible until you did. They
/// are the map's navigation, so they belong where the other pages keep
/// theirs — and there is exactly one of each, here, rather than a toggle in
/// the sidebar and a second copy in the toolbar.
///
/// The captions are not decoration. Both the node directory and the terrain
/// forecast collect "enabled but invisible" reports, because for both of
/// them drawing nothing is a common and honest outcome — most of a harvested
/// directory has no position, and in rolling ground most untried paths really
/// are blocked. A layer that can legitimately draw nothing has to say so, or
/// it is indistinguishable from a broken one.
struct MapLayerRows: View {

    @ObservedObject var status: MapLayerStatus

    @AppStorage("stations.showsPaths") private var showsPaths = false
    @AppStorage("stations.showsPredictedPaths") private var showsPredictedPaths = false
    @AppStorage("stations.showsDirectoryNodes") private var showsDirectoryNodes = false
    @AppStorage("stations.showsCoverageRing") private var showsCoverageRing = true
    @AppStorage("stations.hidesDistantStations") private var hidesDistantStations = false

    var body: some View {
        Section("Layers") {
            layer("Observed Paths", "point.topleft.down.to.point.bottomright.curvepath",
                  isOn: $showsPaths,
                  help: "Paths observed between stations. Colour is evidence: green completed a "
                      + "connect end to end, blue arrived through a digipeater, teal was heard "
                      + "direct, grey dashed is inferred from a shared digipeater, and red means "
                      + "connect attempts went unanswered.")

            layer("Predicted Paths", "point.topleft.down.to.point.bottomright.curvepath.fill",
                  isOn: $showsPredictedPaths,
                  caption: status.hasTerrain ? status.forecastSummary : "Needs terrain data",
                  enabled: status.hasTerrain,
                  help: status.hasTerrain
                      ? "Where the stored terrain says a signal would cross between stations "
                        + "never heard talking. A forecast from ground elevation and Fresnel "
                        + "geometry \u{2014} not a measurement, which is why it is drawn differently."
                      : "Needs terrain data. Download the elevation tiles for this area from "
                        + "the map's Terrain menu first.")

            layer("Node Directory", "list.bullet.indent",
                  isOn: $showsDirectoryNodes,
                  caption: status.directoryCaption,
                  help: "Every station the network has claimed reachable that can be placed from "
                      + "cached positions. Dashed when the position is the operator's address "
                      + "rather than the node's own. Nothing is looked up online for this layer.")

            layer("Coverage Rings", "circle.dashed",
                  isOn: $showsCoverageRing,
                  help: "Rings drawn from the stations that answered you directly \u{2014} a UA, DM "
                      + "or FRMR to your frames proves they decoded you. Measurements, not a "
                      + "propagation model.")

            layer("Hide Distant Stations", "arrow.down.right.and.arrow.up.left",
                  isOn: $hidesDistantStations,
                  caption: distantCaption,
                  enabled: status.distantCount > 0,
                  help: "Sets aside stations too far away to have arrived by radio. One "
                      + "internet-bridged station on the far coast stretches the zoom until every "
                      + "local station is a single cluster.")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    /// Named even when the filter is off, so the operator meets the feature
    /// here rather than discovering it by accident.
    private var distantCaption: String? {
        switch status.distantCount {
        case 0: return nil
        case 1: return hidesDistantStations ? "1 hidden" : "1 too far to have been heard"
        default:
            return hidesDistantStations
                ? "\(status.distantCount) hidden"
                : "\(status.distantCount) too far to have been heard"
        }
    }

    @ViewBuilder
    private func layer(_ title: String, _ symbol: String,
                       isOn: Binding<Bool>,
                       caption: String? = nil,
                       enabled: Bool = true,
                       help: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Toggle(isOn: isOn) {
                Label(title, systemImage: symbol)
            }
            .disabled(!enabled)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    // Clear of the switch, and lined up under the label
                    // rather than under the icon.
                    .padding(.leading, 22)
            }
        }
        .help(help)
    }
}
