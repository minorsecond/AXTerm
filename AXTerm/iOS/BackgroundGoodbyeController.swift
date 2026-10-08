#if os(iOS)
import UIKit

/// Says goodbye on the air when the app leaves the screen for good.
///
/// iOS suspends AXTerm a few seconds after it goes to the background, and
/// its links died without a DISC (the iOS side of smoke run 2026-10-03-1,
/// issue 85). Leaving the screen asks iOS for background time; after a
/// short grace, so a quick trip to another app keeps the session, every
/// live link that will not survive the suspension gets its DISC and time to
/// settle (`BackgroundGoodbye.plan`), then the time is handed back. Coming
/// back first cancels it.
///
/// A link through a Bluetooth TNC is left up (park rehearsal 2026-10-08,
/// operator's approval): the app's background mode, bluetooth-central, wakes
/// it for every frame the TNC passes up, so a download carries on and each
/// frame is acknowledged. The app sleeps between frames, though, so its own
/// timers wait: a send from this device that loses an acknowledgment stalls
/// until the other station polls or the operator comes back.
@MainActor
final class BackgroundGoodbyeController {
    private weak var coordinator: SessionCoordinator?
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var pendingGoodbye: DispatchWorkItem?

    /// Takes no coordinator: the root view builds this in its initializer,
    /// which runs on every settings change, and reaching for the coordinator
    /// there built the station's services again each time (issue 104). The
    /// coordinator comes with `enteredBackground(coordinator:)`.
    init() {}

    /// Whether a radio's link outlasts the suspension; set by the root view,
    /// which knows each radio's transport.
    var survives: (RadioID) -> Bool = { _ in false }

    func enteredBackground(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        guard task == .invalid else { return }
        guard coordinator.hasLiveLinks(endingInBackground: survives) else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "AXTerm goodbye") { [weak self] in
            // Out of time: iOS is about to suspend the app regardless.
            MainActor.assumeIsolated { self?.finish() }
        }
        guard task != .invalid else { return }
        let plan = BackgroundGoodbye.plan(
            backgroundTimeRemaining: UIApplication.shared.backgroundTimeRemaining)
        let goodbye = DispatchWorkItem { [weak self] in self?.sayGoodbye(settleCap: plan.settleCap) }
        pendingGoodbye = goodbye
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.grace, execute: goodbye)
    }

    func becameActive() {
        // Back before the goodbye went out: the session carries on.
        pendingGoodbye?.cancel()
        pendingGoodbye = nil
        finish()
    }

    private func sayGoodbye(settleCap: TimeInterval) {
        pendingGoodbye = nil
        guard let coordinator, coordinator.prepareForTermination(keeping: survives) > 0 else { return finish() }
        coordinator.packetEngine?.appendSystemNotification(
            "AXTerm left the screen, so its sessions were closed before iOS suspends it.")
        coordinator.whenTerminationDisconnectsSettle(
            minimum: 0.4, deadline: Date().addingTimeInterval(settleCap)) { [weak self] in
            self?.finish()
        }
    }

    private func finish() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
#endif
