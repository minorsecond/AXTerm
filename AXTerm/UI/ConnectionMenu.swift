import Foundation

#if os(macOS)

/// The Connection menu: one item for every radio, and one per radio when
/// there are several, worded as the menu bar icon words them. Its item used
/// to take its action from the focused window, so with AXTerm in the
/// background it did nothing and stayed enabled (2026-10-10).
enum ConnectionMenu {
    enum Target: Equatable { case all, radio(RadioID) }
    struct Item: Equatable { let title: String; let target: Target }

    static func items(_ radios: [(id: RadioID, name: String, status: ConnectionStatus)]) -> [Item] {
        typealias Model = StatusItemController.MenuModel
        var items = [Item(title: Model.connectionAction(for: radios.map(\.status)), target: .all)]
        guard radios.count > 1 else { return items }
        for radio in radios {
            items.append(Item(title: "\(Model.connectionAction(for: radio.status)) \(radio.name)",
                              target: .radio(radio.id)))
        }
        return items
    }

    /// Carries out an item against the engine.
    @MainActor
    static func perform(_ target: Target, client: PacketEngine) {
        switch target {
        case .all:
            let anyUp = client.radioSummaries.contains { $0.status == .connected || $0.status == .connecting }
            if anyUp || client.status == .connected || client.status == .connecting {
                client.disconnect(reason: "user toggle connection (menu)")
            } else {
                client.connectUsingSettings()
            }
        case .radio(let radio):
            switch client.radioManager.state(of: radio) {
            case .connected, .connecting: client.radioManager.close(radio)
            case .disconnected, .failed: client.radioManager.open(radio)
            }
        }
    }
}
#endif
