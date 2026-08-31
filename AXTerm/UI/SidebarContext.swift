import Foundation

/// What fills the primary sidebar below the view list.
///
/// The sidebar's lower half is *what the frontmost page navigates by*. For
/// the pages built on received traffic that is the radio context — what can
/// be reached, which circuits are live, who has been heard. For Mail it is
/// the folder list.
///
/// Mail used to carry its folders in a column of its own, which put two
/// navigation columns side by side before any content began: Views, then
/// Reachable, then Stations, then Folders, then the message list. Moving the
/// folders into the sidebar they belong in is what removes the column —
/// merely emptying the sidebar on Mail left the same four columns with one
/// of them blank.
nonisolated enum SidebarContext {

    enum Section: Equatable, Sendable {
        /// Reachable nodes, live circuits, heard stations.
        case radio
        /// The mailbox's folders, hosted here rather than in a column.
        case mailFolders
    }

    static func section(for item: NavigationItem) -> Section {
        switch item {
        case .mail:
            return .mailFolders
        // BBS included: it is a single pane with no navigation column of
        // its own, and its traffic arrives over the same radio the rest of
        // this context describes.
        //
        // Listed rather than defaulted so a new page has to be decided
        // about — a silent fallthrough is how this drifts.
        case .terminal, .packets, .routes, .nodes, .analytics, .map, .bbs:
            return .radio
        }
    }
}
