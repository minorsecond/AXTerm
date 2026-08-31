import Foundation

/// What belongs in the primary sidebar for the page in front.
///
/// The sidebar carries the radio context — what can be reached, which
/// circuits are live, who has been heard. That serves the pages built on
/// received traffic, and nothing else.
///
/// Mail and BBS bring their own navigation column, so showing it there left
/// the operator with two sidebars before the content started: Views, then
/// Reachable via nodes, then Stations, then Folders, then the message list.
nonisolated enum SidebarContext {

    static func showsRadioSections(for item: NavigationItem) -> Bool {
        switch item {
        // Their own second column, and nothing here shapes them.
        case .mail, .bbs:
            return false
        // Listed rather than defaulted so a new page has to be decided
        // about — a silent yes is how this drifts back.
        case .terminal, .packets, .routes, .nodes, .analytics, .map:
            return true
        }
    }
}
