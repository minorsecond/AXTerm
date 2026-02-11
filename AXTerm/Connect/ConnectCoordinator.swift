import Foundation
import Combine

final class ConnectCoordinator: ObservableObject {
    @Published private(set) var pendingRequest: ConnectRequest?
    @Published var activeContext: ConnectSourceContext = .terminal

    var navigateToTerminal: (() -> Void)?
    private var lastModeByStation: [String: ConnectBarMode] = [:]

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

    func preferredMode(for station: String, hasNetRomRoute: Bool) -> ConnectBarMode {
        let normalized = CallsignValidator.normalize(station)
        if let remembered = lastModeByStation[normalized] {
            return remembered
        }
        return hasNetRomRoute ? .netrom : .ax25
    }
}
