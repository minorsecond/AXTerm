import Foundation

/// What fills the primary sidebar below the view list.
///
/// The sidebar's lower half is *what the frontmost page navigates by*. That
/// is one rule, not a list of exceptions, and it decides every page:
///
/// * Terminal, Packets and Analytics are filtered by station, and the
///   station list is the filter — see `stationFilterApplies`.
/// * Routes and Nodes are navigated by node: a "Reachable via" row *is* the
///   Nodes page's filter, which is why it lights up when that page shows it.
/// * Map is navigated by layer. The toggles were buried in a toolbar menu,
///   which is a strange place for the controls that decide what the page
///   draws.
/// * Mail is navigated by folder, BBS by pane.
///
/// Mail and BBS both used to carry that navigation *inside* the page — a
/// folder column of its own, a segmented picker across the top — which is
/// what put two navigation columns side by side before any content began.
nonisolated enum SidebarContext {

    enum Section: Equatable, Sendable {
        /// Reachable nodes, live circuits, heard stations.
        case radio
        /// What the map draws.
        case mapLayers
        /// The mailbox's folders.
        case mailFolders
        /// The BBS's four panes.
        case bbsPanes
    }

    /// Listed page by page rather than defaulted, so a new page has to be
    /// decided about. A silent fallthrough to `.radio` is how a sidebar
    /// stops matching the thing beside it.
    static func section(for item: NavigationItem) -> Section {
        switch item {
        case .map:
            return .mapLayers
        case .mail:
            return .mailFolders
        case .bbs:
            return .bbsPanes
        case .terminal, .packets, .routes, .nodes, .analytics:
            return .radio
        }
    }
}
