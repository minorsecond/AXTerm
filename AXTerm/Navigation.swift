import Foundation

// Moved out of ContentView so both app shells can use them: ContentView is
// the macOS window layout and does not build for iOS, but the sections it
// names — terminal, packets, routes, analytics, map, mail — are the same on
// every platform.

nonisolated enum NavigationItem: String, Hashable, CaseIterable {
    case terminal = "Terminal"
    case packets = "Packets"
    case routes = "Routes"
    case analytics = "Analytics"
    case map = "Map"
    case mail = "Mail"
    //case raw = "Raw"
}

/// Which tier of network evidence produced an adaptive sample.
nonisolated enum AdaptiveAggregateScope: Equatable, Sendable {
    /// Links involving my own station — ground truth about my RF paths.
    case localLinks
    /// Third-party traffic on the shared channel — weaker, condition-level evidence.
    case channelWide

    var sourceLabel: String {
        switch self {
        case .localLinks: return "network"
        case .channelWide: return "network (channel-wide)"
        }
    }
}
