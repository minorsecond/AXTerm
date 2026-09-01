import Foundation

// Moved out of ContentView so both app shells can use them: ContentView is
// the macOS window layout and does not build for iOS, but the sections it
// names — terminal, packets, routes, analytics, map, mail — are the same on
// every platform.

nonisolated enum NavigationItem: String, Hashable, CaseIterable {
    case terminal = "Terminal"
    case packets = "Packets"
    case routes = "Routes"
    case nodes = "Nodes"
    case analytics = "Analytics"
    case map = "Map"
    case mail = "Mail"
    case bbs = "BBS"
    //case raw = "Raw"
}

extension NavigationItem {
    /// The number key that selects this destination from the View menu.
    ///
    /// Sidebar order, so the numbers match what the operator is looking at.
    /// The menu and the sidebar drifted apart once: the menu stopped after
    /// five destinations, leaving Nodes, Map and BBS with no menu item and
    /// no shortcut at all, and numbering Analytics as 4 while it sat fifth
    /// in the sidebar. `ViewMenuTests` now fails if that recurs.
    var menuShortcut: Character {
        switch self {
        case .terminal: return "1"
        case .packets: return "2"
        case .routes: return "3"
        case .nodes: return "4"
        case .analytics: return "5"
        case .map: return "6"
        case .mail: return "7"
        case .bbs: return "8"
        }
    }
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
