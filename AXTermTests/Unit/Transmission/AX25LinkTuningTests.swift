import XCTest
@testable import AXTerm

/// Manual PACLEN, K and N2 survive a relaunch, a visit to the Packet Node
/// page and "Clear All Learned Data". All three used to lose them.
@MainActor
final class AX25LinkTuningTests: XCTestCase {

    func testManualValuesRoundTripThroughAdaptiveSettings() {
        var adaptive = TxAdaptiveSettings()
        adaptive.windowSize.mode = .manual
        adaptive.windowSize.manualValue = 4
        adaptive.maxRetries.mode = .manual
        adaptive.maxRetries.manualValue = 8

        let tuning = AX25LinkTuning(adaptive)
        XCTAssertEqual(tuning, AX25LinkTuning(paclen: nil, windowSize: 4, maxRetries: 8))

        let restored = tuning.applied(to: TxAdaptiveSettings())
        XCTAssertEqual(restored.paclen.mode, .auto)
        XCTAssertEqual(restored.windowSize.mode, .manual)
        XCTAssertEqual(restored.windowSize.manualValue, 4)
        XCTAssertEqual(restored.maxRetries.manualValue, 8)
    }

    func testAStoredValueOutsideTheRangeIsClamped() {
        let restored = AX25LinkTuning(paclen: 9_999, windowSize: 0).applied(to: TxAdaptiveSettings())
        XCTAssertEqual(restored.paclen.manualValue, 256)
        XCTAssertEqual(restored.windowSize.manualValue, 1)
    }

    func testTheSettingsStoreKeepsTheTuning() {
        let defaults = TestDefaults.make("AX25LinkTuning")
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.ax25LinkTuning, AX25LinkTuning(), "all Auto until set")

        store.ax25LinkTuning = AX25LinkTuning(paclen: 64, windowSize: 3)
        let reopened = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.ax25LinkTuning, AX25LinkTuning(paclen: 64, windowSize: 3))
    }

    func testClearingLearnedDataKeepsTheOperatorsChoices() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.adaptiveTransmissionEnabled = true
        coordinator.globalAdaptiveSettings.windowSize.mode = .manual
        coordinator.globalAdaptiveSettings.windowSize.manualValue = 5
        coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = false
        coordinator.globalAdaptiveSettings.paclen.currentAdaptive = 64

        coordinator.clearAllLearned()

        let after = coordinator.globalAdaptiveSettings
        XCTAssertEqual(after.windowSize.mode, .manual)
        XCTAssertEqual(after.windowSize.manualValue, 5)
        XCTAssertFalse(after.axdpExtensionsEnabled, "AXDP stays off")
        XCTAssertEqual(after.paclen.currentAdaptive, 128, "what was learned is cleared")
    }
}
