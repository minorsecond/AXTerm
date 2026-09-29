import Foundation

/// Which of the root window's two sheets is showing.
///
/// SwiftUI honours a single `.sheet` per view: attach two and the second
/// silently shadows the first. The main window has two independent sources
/// that each want to present — a tapped packet and a tapped callsign — and
/// wiring them as two modifiers is why the identity page opened once and then
/// refused to reappear after being dismissed.
///
/// Both are routed through one modifier and this one value. Kept out of the
/// view so the merge rules can be tested; the view holds only the binding.
nonisolated enum RootSheetRoute: Identifiable, Equatable {
    case inspector(UUID)
    case profile(NodeProfileCoordinator.Presentation)

    nonisolated var id: String {
        switch self {
        case .inspector(let packetID): return "inspector:\(packetID.uuidString)"
        case .profile(let presentation): return "profile:\(presentation.id)"
        }
    }

    /// What should be on screen, given both sources.
    ///
    /// The inspector wins a tie. Both being set at once is already a bug —
    /// the setter below clears the other whenever one is raised — so this is
    /// only about behaving predictably if it ever happens.
    static func current(inspector packetID: UUID?,
                        profile presentation: NodeProfileCoordinator.Presentation?)
        -> RootSheetRoute? {
        if let packetID { return .inspector(packetID) }
        if let presentation { return .profile(presentation) }
        return nil
    }

    /// What each source becomes when the sheet changes.
    ///
    /// Dismissal clears *both*. Leaving the other source set would make the
    /// next request a no-op, because the state SwiftUI watches would never
    /// change — which is exactly the "opens once, then never again" symptom.
    static func apply(_ route: RootSheetRoute?)
        -> (inspector: UUID?, profile: NodeProfileCoordinator.Presentation?) {
        switch route {
        case .inspector(let packetID): return (packetID, nil)
        case .profile(let presentation): return (nil, presentation)
        case nil: return (nil, nil)
        }
    }
}
