import Foundation

/// Which face of the mailbox is showing.
///
/// Top level rather than nested in `BBSView`, because the sidebar chooses it
/// and the page renders it — the selection is the shell's now, the way the
/// mail folder is.
nonisolated enum BBSPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case messages = "Messages"
    case callers = "Callers"
    case directory = "Directory"
    case files = "Files"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .messages: return "tray.full"
        case .callers: return "person.wave.2"
        case .directory: return "book.closed"
        case .files: return "folder"
        }
    }
}
