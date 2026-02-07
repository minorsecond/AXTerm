//
//  TxAdaptiveSettingsViewModelTests.swift
//  AXTermTests
//
//  TDD tests for adaptive settings view model.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 4.1
//
//  Settings UX requirement (from spec):
//  - Mode: Auto / Manual per parameter
//  - If Manual: value picker enabled
//  - If Auto: show "Current" + "Suggested" + "Reason"
//

import XCTest
@testable import AXTerm

final class TxAdaptiveSettingsViewModelTests: XCTestCase {

    // MARK: - Initialization Tests

    func testViewModelInitialization() {
        let settings = TxAdaptiveSettings()
        let viewModel = TxAdaptiveSettingsViewModel(settings: settings)

        XCTAssertNotNil(viewModel)
        XCTAssertEqual(viewModel.settings.paclen.mode, .auto)
    }

    func testViewModelPreservesSettings() {
        var settings = TxAdaptiveSettings()
        settings.paclen.mode = .manual
        settings.paclen.manualValue = 64

        let viewModel = TxAdaptiveSettingsViewModel(settings: settings)

        XCTAssertEqual(viewModel.settings.paclen.mode, .manual)
        XCTAssertEqual(viewModel.settings.paclen.manualValue, 64)
    }

    // MARK: - Mode Toggle Tests

    func testTogglePaclenMode() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        XCTAssertEqual(viewModel.settings.paclen.mode, .auto)

        viewModel.toggleMode(for: \.paclen)

        XCTAssertEqual(viewModel.settings.paclen.mode, .manual)

        viewModel.toggleMode(for: \.paclen)

        XCTAssertEqual(viewModel.settings.paclen.mode, .auto)
    }

    func testToggleWindowSizeMode() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        XCTAssertEqual(viewModel.settings.windowSize.mode, .auto)

        viewModel.toggleMode(for: \.windowSize)

        XCTAssertEqual(viewModel.settings.windowSize.mode, .manual)
    }

    func testToggleMaxRetriesMode() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        XCTAssertEqual(viewModel.settings.maxRetries.mode, .auto)

        viewModel.toggleMode(for: \.maxRetries)

        XCTAssertEqual(viewModel.settings.maxRetries.mode, .manual)
    }

    // MARK: - Manual Value Tests

    func testSetPaclenManualValue() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        viewModel.setManualValue(64, for: \.paclen)

        XCTAssertEqual(viewModel.settings.paclen.manualValue, 64)
    }

    func testSetWindowSizeManualValue() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        viewModel.setManualValue(4, for: \.windowSize)

        XCTAssertEqual(viewModel.settings.windowSize.manualValue, 4)
    }

    func testManualValueClampedToRange() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        // Try to set value above range
        viewModel.setManualValue(500, for: \.paclen)

        // Should be clamped when accessing effectiveValue
        XCTAssertEqual(viewModel.settings.paclen.clampedManualValue, 256)
    }

    // MARK: - Effective Value Tests

    func testEffectiveValueInAutoMode() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        // Set adaptive value
        viewModel.settings.paclen.currentAdaptive = 96

        XCTAssertEqual(viewModel.settings.paclen.effectiveValue, 96)
    }

    func testEffectiveValueInManualMode() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        viewModel.settings.paclen.mode = .manual
        viewModel.settings.paclen.manualValue = 64
        viewModel.settings.paclen.currentAdaptive = 128

        XCTAssertEqual(viewModel.settings.paclen.effectiveValue, 64)
    }

    // MARK: - Display Helper Tests

    func testDisplayReasonInAutoMode() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        viewModel.settings.paclen.adaptiveReason = "High loss rate detected"

        XCTAssertNotNil(viewModel.displayReason(for: \.paclen))
        XCTAssertEqual(viewModel.displayReason(for: \.paclen), "High loss rate detected")
    }

    func testDisplayReasonNilInManualMode() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        viewModel.settings.paclen.mode = .manual
        viewModel.settings.paclen.adaptiveReason = "High loss rate detected"

        XCTAssertNil(viewModel.displayReason(for: \.paclen))
    }

    func testIsManualMode() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        XCTAssertFalse(viewModel.isManualMode(for: \.paclen))

        viewModel.toggleMode(for: \.paclen)

        XCTAssertTrue(viewModel.isManualMode(for: \.paclen))
    }

    // MARK: - AXDP Settings Tests

    func testCompressionToggle() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        XCTAssertTrue(viewModel.settings.compressionEnabled)

        viewModel.settings.compressionEnabled = false

        XCTAssertFalse(viewModel.settings.compressionEnabled)
    }

    func testCompressionAlgorithmSelection() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        XCTAssertEqual(viewModel.settings.compressionAlgorithm, .lz4)

        viewModel.settings.compressionAlgorithm = .deflate

        XCTAssertEqual(viewModel.settings.compressionAlgorithm, .deflate)
    }

    func testExtensionsToggle() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        XCTAssertTrue(viewModel.settings.axdpExtensionsEnabled)

        viewModel.settings.axdpExtensionsEnabled = false

        XCTAssertFalse(viewModel.settings.axdpExtensionsEnabled)
    }

    // MARK: - RTO Double Value Tests

    func testSetRtoMinManualValue() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        viewModel.setManualDoubleValue(2.0, for: \.rtoMin)

        XCTAssertEqual(viewModel.settings.rtoMin.manualValue, 2.0, accuracy: 0.01)
    }

    func testSetRtoMaxManualValue() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        viewModel.setManualDoubleValue(45.0, for: \.rtoMax)

        XCTAssertEqual(viewModel.settings.rtoMax.manualValue, 45.0, accuracy: 0.01)
    }

    // MARK: - All Settings List Tests

    func testAllAdaptiveSettingsCount() {
        let settings = TxAdaptiveSettings()

        // Should have 5 adaptive settings
        XCTAssertEqual(settings.allAdaptiveSettings.count, 5)
    }

    // MARK: - Reset to Defaults Tests

    func testResetToDefaults() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        // Modify settings
        viewModel.settings.paclen.mode = .manual
        viewModel.settings.paclen.manualValue = 64
        viewModel.settings.windowSize.mode = .manual
        viewModel.settings.compressionEnabled = false

        // Reset
        viewModel.resetToDefaults()

        // Check all back to default
        XCTAssertEqual(viewModel.settings.paclen.mode, .auto)
        XCTAssertEqual(viewModel.settings.paclen.manualValue, 128)
        XCTAssertEqual(viewModel.settings.windowSize.mode, .auto)
        XCTAssertTrue(viewModel.settings.compressionEnabled)
    }

    // MARK: - Link Quality Update Tests

    func testUpdateFromLinkQualityHighLoss() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        viewModel.updateFromLinkQuality(lossRate: 0.25, etx: 2.5, srtt: 3.0)

        // With high loss, paclen should be reduced
        XCTAssertEqual(viewModel.settings.paclen.currentAdaptive, 64)
        XCTAssertNotNil(viewModel.settings.paclen.adaptiveReason)

        // Window size should be 1 for high loss
        XCTAssertEqual(viewModel.settings.windowSize.currentAdaptive, 1)
    }

    func testUpdateFromLinkQualityGoodLink() {
        var viewModel = TxAdaptiveSettingsViewModel(settings: TxAdaptiveSettings())

        viewModel.updateFromLinkQuality(lossRate: 0.02, etx: 1.1, srtt: 1.5)

        // With good link, paclen should be default
        XCTAssertEqual(viewModel.settings.paclen.currentAdaptive, 128)

        // Window size should increase
        XCTAssertGreaterThan(viewModel.settings.windowSize.currentAdaptive, 2)
    }
}
