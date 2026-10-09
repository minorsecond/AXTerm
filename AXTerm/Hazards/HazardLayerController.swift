import Combine
import Foundation

/// Runs the hazard layers for the map: the app ticks it on a timer, and it
/// fetches only when `HazardRefreshPolicy` says so. A layer that is off is
/// not drawn and not fetched; its last copy stays on disk for when it is
/// turned back on.
@MainActor
final class HazardLayerController: ObservableObject {
    let nws: NWSAlertLayer

    /// Whether the NWS layer is on, as of the last tick.
    @Published private(set) var nwsEnabled = false

    private let now: () -> Date
    private var lastAttempt: Date?
    private var lastPoint: GreatCircle.Point?
    private var cancellable: AnyCancellable?

    init(nws: NWSAlertLayer, now: @escaping () -> Date = Date.init) {
        self.nws = nws
        self.now = now
        // The map redraws when the layer's alerts change.
        cancellable = nws.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// What the map draws: the layer's alerts while it is on, nothing off.
    var drawnFeatures: [HazardFeature] { nwsEnabled ? nws.features : [] }

    func tick(nwsEnabled enabled: Bool, position: GreatCircle.Point?) async {
        if enabled != nwsEnabled {
            nwsEnabled = enabled
            // Back on: show the saved copy, at its real age, until a fetch.
            if enabled, nws.features.isEmpty { nws.loadCached() }
        }
        guard HazardRefreshPolicy.shouldRefresh(enabled: enabled, position: position,
                                                lastAttempt: lastAttempt, lastPoint: lastPoint,
                                                now: now()), let position else { return }
        lastAttempt = now()
        lastPoint = position
        await nws.refresh(near: position)
    }
}
