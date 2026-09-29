import Foundation
import Combine

final class ConnectCoordinator: ObservableObject {
    @Published private(set) var pendingRequest: ConnectRequest?
    @Published var activeContext: ConnectSourceContext = .terminal

    var navigateToTerminal: (() -> Void)?
    private var lastModeByStation: [String: ConnectBarMode] = [:]

    // The project defaults to MainActor isolation, so this class gets an
    // implicit isolated deinit — and those dispatch through
    // `swift_task_deinitOnExecutor`, which crashes in libmalloc when the object
    // is released synchronously. `ConnectBarViewModel` and
    // `DestinationPickerViewModel` already carry the same opt-out for the same
    // reason; this one was missed, and two test files were quietly retaining
    // every instance for the life of the process to avoid tripping it.
    //
    // The deinit touches no isolated state, so opting out is safe.
    nonisolated deinit {}

    func requestConnect(_ request: ConnectRequest) {
        let normalized = CallsignValidator.normalize(request.intent.to)
        if !normalized.isEmpty {
            lastModeByStation[normalized] = request.mode
        }
        pendingRequest = request
        if ConnectPrefillLogic.shouldNavigateOnConnect(request) {
            navigateToTerminal?()
        }
    }

    func consumeRequest(id: UUID) {
        guard pendingRequest?.id == id else { return }
        pendingRequest = nil
    }

    /// How to reach a station, best guess first.
    ///
    /// - Parameter heardVia: the digipeaters that actually repeated this
    ///   station's most recent frame — hops proven to work, most recently.
    ///   Empty means the last frame arrived direct.
    ///
    /// The `heardVia` tier is the one that was missing. A station AXTerm has
    /// only ever heard through a digipeater is not reachable directly, the
    /// sidebar row already says so in as many words — "Via DRLNOD" — and
    /// connecting direct anyway ignores the single piece of evidence held
    /// about how to get there. What the row displays and what the click does
    /// should be the same fact.
    func preferredMode(for station: String,
                       hasNetRomRoute: Bool,
                       heardVia: [String] = []) -> ConnectBarMode {
        let normalized = CallsignValidator.normalize(station)
        // What the operator chose last for this station outranks any guess.
        if let remembered = lastModeByStation[normalized] {
            return remembered
        }
        if hasNetRomRoute { return .netrom }
        if !heardVia.isEmpty { return .ax25ViaDigi }
        return .ax25
    }

    /// The path to transmit along, given how a station was last heard.
    ///
    /// Reversed: `heardVia` is ordered as the frame travelled *to* us, and the
    /// way back out is the same hops in the opposite order. It makes no
    /// difference through a single digipeater and every difference through two.
    nonisolated static func returnPath(heardVia: [String]) -> [String] {
        heardVia.reversed()
    }
}
