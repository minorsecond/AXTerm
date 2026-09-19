import XCTest
@testable import AXTerm

/// Telling the neighbours we are back.
///
/// A station that sleeps disappears from the network without saying so, and
/// NET/ROM routes to it age out on their own. The steady announcement cadence
/// can be an hour, so a Mac woken at nine would otherwise be unreachable until
/// ten even with every link back up inside a second.
@MainActor
final class WakeAnnouncementTests: XCTestCase {

    private func settings(announcing: Bool) -> AppSettingsStore {
        let suite = "wake-announcement-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = AppSettingsStore(defaults: defaults)
        store.netRomAdvertiseSelf = announcing
        store.netRomNodeAlias = "AXTEST"
        return store
    }

    // MARK: - Off

    /// A station that does not announce itself has nothing to announce on
    /// waking. Arming a shot here would write this station into other
    /// operators' routing tables against a setting they turned off.
    func testAStationThatDoesNotAnnounceStaysQuiet() {
        let coordinator = SessionCoordinator()
        coordinator.applyNetRomNodeSettings(settings(announcing: false))
        XCTAssertFalse(coordinator.isAnnouncingNodes)

        coordinator.announceAfterWake()

        XCTAssertFalse(coordinator.testWakeAnnouncementIsPending)
    }

    /// Nothing configured at all is the same answer, and must not crash on the
    /// way to it.
    func testAnUnconfiguredCoordinatorStaysQuiet() {
        let coordinator = SessionCoordinator()
        coordinator.announceAfterWake()
        XCTAssertFalse(coordinator.testWakeAnnouncementIsPending)
    }

    // MARK: - On

    /// The one that matters: a node that announces gets a shot armed on the
    /// way back, rather than waiting out an interval that may be an hour.
    func testAnAnnouncingNodeArmsAShotOnWaking() {
        let coordinator = SessionCoordinator()
        coordinator.applyNetRomNodeSettings(settings(announcing: true))
        XCTAssertTrue(coordinator.isAnnouncingNodes)

        coordinator.announceAfterWake()

        XCTAssertTrue(coordinator.testWakeAnnouncementIsPending)
    }

    /// Waking once puts one NODES broadcast on the air, not one per observer
    /// that noticed the wake. Six broadcasts carrying six prefixes of a node
    /// alias is a mistake this file has made before (2026-08-27).
    func testWakingTwiceDoesNotStackUpTwoShots() {
        let coordinator = SessionCoordinator()
        coordinator.applyNetRomNodeSettings(settings(announcing: true))

        coordinator.announceAfterWake()
        coordinator.announceAfterWake()

        // The second call invalidates the first timer before arming its own,
        // so exactly one is live.
        XCTAssertTrue(coordinator.testWakeAnnouncementIsPending)
    }

    /// Switching announcing off after a wake cancels the pending shot. The
    /// operator's last word wins over a timer armed before they said it.
    func testTurningAnnouncingOffCancelsThePendingShot() {
        let coordinator = SessionCoordinator()
        coordinator.applyNetRomNodeSettings(settings(announcing: true))
        coordinator.announceAfterWake()
        XCTAssertTrue(coordinator.testWakeAnnouncementIsPending)

        coordinator.applyNetRomNodeSettings(settings(announcing: false))

        XCTAssertFalse(coordinator.testWakeAnnouncementIsPending)
        XCTAssertFalse(coordinator.isAnnouncingNodes)
    }
}
