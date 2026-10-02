//
//  NodePolicyRestoreTests.swift
//  AXTermTests
//
//  The NET/ROM node policy comes back at launch on both platforms. The Mac's
//  root view applied it after building the coordinator; the iOS root never
//  did, so on an iPhone or iPad the node stayed off after a relaunch while
//  its switch still read on, and announcing, the node alias and the radio
//  beacons waited for the operator to open a settings screen.
//
//  The coordinator now applies the policy when it is handed the settings,
//  which both app shells do once at launch. No view is involved here.
//

import XCTest
@testable import AXTerm

@MainActor
final class NodePolicyRestoreTests: XCTestCase {

    private func settings(_ label: String) -> AppSettingsStore {
        let settings = AppSettingsStore(defaults: TestDefaults.make(label))
        settings.myCallsign = "K0EPI"
        settings.netRomNodeAlias = "EPINOD"
        return settings
    }

    func testARunningNodeIsBackOnceTheCoordinatorHasItsSettings() {
        let settings = settings("node-policy-restore-node")
        settings.netRomAcceptInbound = true
        let coordinator = SessionCoordinator()

        coordinator.appSettings = settings

        XCTAssertTrue(coordinator.netRomNodeHost.isEnabled)
        // The node alias answers plain AX.25 connects again, without a visit
        // to settings.
        XCTAssertTrue(coordinator.sessionManager.answeredAddresses
            .contains { $0.display == "EPINOD" },
            "answering: \(coordinator.sessionManager.answeredAddresses.map(\.display))")
    }

    func testAnnouncingResumesWithTheLaunchWarmUpRatherThanAtOnce() {
        let settings = settings("node-policy-restore-announce")
        settings.netRomAdvertiseSelf = true
        let coordinator = SessionCoordinator()

        coordinator.appSettings = settings

        XCTAssertTrue(coordinator.isAnnouncingNodes)
        // The restore path, not the "just switched on" path: the first NODES
        // waits for the warm-up so it never goes out before the radio is up.
        XCTAssertTrue(coordinator.testWakeAnnouncementIsPending)
    }

    func testAStationWithTheNodeOffStaysOff() {
        let coordinator = SessionCoordinator()

        coordinator.appSettings = settings("node-policy-restore-off")

        XCTAssertFalse(coordinator.netRomNodeHost.isEnabled)
        XCTAssertFalse(coordinator.isAnnouncingNodes)
        XCTAssertFalse(coordinator.sessionManager.answeredAddresses
            .contains { $0.display == "EPINOD" })
    }
}
