import Foundation
import Combine

final class ConnectCoordinator: ObservableObject {
    @Published private(set) var pendingRequest: ConnectRequest?
    @Published var activeContext: ConnectSourceContext = .terminal

    var navigateToTerminal: (() -> Void)?

    func requestConnect(_ request: ConnectRequest) {
        pendingRequest = request
        if ConnectPrefillLogic.shouldNavigateOnConnect(request) {
            navigateToTerminal?()
        }
    }

    func consumeRequest(id: UUID) {
        guard pendingRequest?.id == id else { return }
        pendingRequest = nil
    }
}
