import Foundation

/// Holds the terminal's view model above the view that uses it.
///
/// SwiftUI keeps a `@StateObject` only while its view keeps its place in the
/// hierarchy. The terminal is a view the operator navigates away from, so its
/// model was destroyed and rebuilt on every visit — taking with it everything
/// it knew that has no other home: the relay's phase and planned chain, the
/// delivery state of the last message, which nodes had been explained.
///
/// The AX.25 session itself survived all of that, because it lives in the
/// coordinator. Sessions outlive the UI (CLAUDE.md §5), and so must what the
/// UI knows about them — which means holding the model where the coordinator
/// already lives rather than inside the view.
///
/// Deliberately not `ObservableObject`: nothing observes the box. The model
/// inside publishes its own changes; the box exists only to outlive the view.
final class TerminalModelBox {

    private var key: String?
    private var stored: ObservableTerminalTxViewModel?

    init() {}

    /// Whether a model built for `existing` still serves `wanted`.
    ///
    /// A change of the station's own callsign really is a different station:
    /// its sessions, relay state and identity belong to the old one, and
    /// carrying them across would attribute one operator's link to another.
    static func needsRebuild(existing: String?, wanted: String) -> Bool {
        guard let existing else { return true }
        return existing.caseInsensitiveCompare(wanted) != .orderedSame
    }

    func model(sourceCall: String,
               make: () -> ObservableTerminalTxViewModel) -> ObservableTerminalTxViewModel {
        if let stored, !Self.needsRebuild(existing: key, wanted: sourceCall) {
            return stored
        }
        let fresh = make()
        key = sourceCall
        stored = fresh
        return fresh
    }
}
