//
//  AdaptiveSettingsTests.swift
//  AXTermTests
//
//  TDD tests for adaptive parameter settings (Auto/Manual mode).
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 4.1
//

import XCTest
@testable import AXTerm

final class AdaptiveSettingsTests: XCTestCase {

    // MARK: - Settings Mode Tests

    func testAdaptiveSettingsModes() {
        XCTAssertEqual(AdaptiveMode.auto.rawValue, "auto")
        XCTAssertEqual(AdaptiveMode.manual.rawValue, "manual")
    }

    func testAdaptiveSettingDefaultsToAuto() {
        let setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        XCTAssertEqual(setting.mode, .auto)
        XCTAssertEqual(setting.manualValue, 128)
    }

    func testAdaptiveSettingManualOverride() {
        var setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        setting.mode = .manual
        setting.manualValue = 64

        XCTAssertEqual(setting.mode, .manual)
        XCTAssertEqual(setting.manualValue, 64)
    }

    func testAdaptiveSettingEffectiveValue() {
        var setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        // In auto mode, effective = current adaptive
        setting.currentAdaptive = 96
        XCTAssertEqual(setting.effectiveValue, 96)

        // In manual mode, effective = manual
        setting.mode = .manual
        setting.manualValue = 64
        XCTAssertEqual(setting.effectiveValue, 64)
    }

    func testAdaptiveSettingRangeClamping() {
        var setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        // Try to set value below range
        setting.manualValue = 16
        XCTAssertGreaterThanOrEqual(setting.clampedManualValue, 32)

        // Try to set value above range
        setting.manualValue = 500
        XCTAssertLessThanOrEqual(setting.clampedManualValue, 256)
    }

    // MARK: - TxSettings Tests

    func testTxSettingsDefaultValues() {
        let settings = TxAdaptiveSettings()

        XCTAssertEqual(settings.paclen.defaultValue, 128)
        XCTAssertEqual(settings.windowSize.defaultValue, 2)
        XCTAssertEqual(settings.maxRetries.defaultValue, 10)
        XCTAssertEqual(settings.rtoMin.defaultValue, 1.0, accuracy: 0.01)
        XCTAssertEqual(settings.rtoMax.defaultValue, 30.0, accuracy: 0.01)
    }

    func testTxSettingsAllInAutoByDefault() {
        let settings = TxAdaptiveSettings()

        XCTAssertEqual(settings.paclen.mode, .auto)
        XCTAssertEqual(settings.windowSize.mode, .auto)
        XCTAssertEqual(settings.maxRetries.mode, .auto)
        XCTAssertEqual(settings.rtoMin.mode, .auto)
        XCTAssertEqual(settings.rtoMax.mode, .auto)
    }

    func testTxSettingsIndividualOverride() {
        var settings = TxAdaptiveSettings()

        // Override just paclen
        settings.paclen.mode = .manual
        settings.paclen.manualValue = 64

        // Others should still be auto
        XCTAssertEqual(settings.paclen.mode, .manual)
        XCTAssertEqual(settings.windowSize.mode, .auto)
    }

    // MARK: - Reason Display Tests

    func testAdaptiveReasonGeneration() {
        var setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        setting.currentAdaptive = 64
        setting.adaptiveReason = "Loss 28%, ETX 2.7"

        XCTAssertEqual(setting.adaptiveReason, "Loss 28%, ETX 2.7")
    }

    func testAdaptiveReasonInAutoMode() {
        var setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        setting.mode = .auto
        setting.currentAdaptive = 64
        setting.adaptiveReason = "High loss rate"

        // In auto mode, reason should be shown
        XCTAssertNotNil(setting.displayReason)
        XCTAssertTrue(setting.displayReason?.contains("loss") ?? false)
    }

    func testAdaptiveReasonHiddenInManualMode() {
        var setting = AdaptiveSetting<Int>(
            name: "paclen",
            displayName: "Packet Length",
            defaultValue: 128,
            range: 32...256
        )

        setting.mode = .manual
        setting.adaptiveReason = "High loss rate"

        // In manual mode, adaptive reason not relevant
        // (user chose the value)
        XCTAssertNil(setting.displayReason)
    }

    // MARK: - Version Selection Tests

    func testAXDPVersionSelection() {
        var settings = TxAdaptiveSettings()

        // Default should be latest
        XCTAssertEqual(settings.axdpVersion, AXDP.version)

        // Can override to older version
        settings.axdpVersion = 1
        XCTAssertEqual(settings.axdpVersion, 1)
    }

    // MARK: - Compression Settings Tests

    func testCompressionEnabled() {
        var settings = TxAdaptiveSettings()

        XCTAssertTrue(settings.compressionEnabled)

        settings.compressionEnabled = false
        XCTAssertFalse(settings.compressionEnabled)
    }

    func testCompressionAlgorithmSelection() {
        var settings = TxAdaptiveSettings()

        XCTAssertEqual(settings.compressionAlgorithm, .lz4)

        settings.compressionAlgorithm = .deflate
        XCTAssertEqual(settings.compressionAlgorithm, .deflate)
    }

    func testMaxDecompressedPayload() {
        var settings = TxAdaptiveSettings()

        XCTAssertEqual(settings.maxDecompressedPayload, 4096)

        settings.maxDecompressedPayload = 8192
        XCTAssertEqual(settings.maxDecompressedPayload, 8192)

        // Should not exceed absolute max
        settings.maxDecompressedPayload = 16384
        XCTAssertLessThanOrEqual(
            settings.clampedMaxDecompressedPayload,
            AXDPCompression.absoluteMaxDecompressedLen
        )
    }

    // MARK: - AXDP Extension Toggles

    func testAXDPExtensionsEnabled() {
        var settings = TxAdaptiveSettings()

        XCTAssertTrue(settings.axdpExtensionsEnabled)

        settings.axdpExtensionsEnabled = false
        XCTAssertFalse(settings.axdpExtensionsEnabled)
    }

    func testAutoNegotiateCapabilities() {
        var settings = TxAdaptiveSettings()

        XCTAssertFalse(settings.autoNegotiateCapabilities)
        settings.autoNegotiateCapabilities = true
        XCTAssertTrue(settings.autoNegotiateCapabilities)
    }

    // MARK: - updateFromLinkQuality (adaptive learning)

    func testUpdateFromLinkQualityHighLoss() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.3, etx: 2.5, srtt: nil)
        XCTAssertEqual(settings.paclen.currentAdaptive, 64)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 1)
        XCTAssertTrue(settings.paclen.adaptiveReason?.contains("Loss") ?? false)
        XCTAssertEqual(settings.windowSize.adaptiveReason, "High loss - stop-and-wait")
    }

    func testUpdateFromLinkQualityGoodLink() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.05, etx: 1.2, srtt: nil)
        XCTAssertEqual(settings.paclen.currentAdaptive, 128)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 3) // min(4, defaultValue+1) with default 2
        XCTAssertEqual(settings.windowSize.adaptiveReason, "Good link quality")
    }

    func testUpdateFromLinkQualityWithSrttSetsRtoReasons() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.1, etx: 1.5, srtt: 2.0)
        XCTAssertNotNil(settings.rtoMin.adaptiveReason)
        XCTAssertTrue(settings.rtoMin.adaptiveReason?.contains("RTT") ?? false)
        XCTAssertNotNil(settings.rtoMax.adaptiveReason)
    }

    func testUpdateFromLinkQualityModerateLoss() {
        var settings = TxAdaptiveSettings()
        settings.paclen.currentAdaptive = 256
        settings.updateFromLinkQuality(lossRate: 0.15, etx: 1.8, srtt: nil)
        XCTAssertLessThanOrEqual(settings.paclen.currentAdaptive, 128)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 2) // default
    }

    func testUpdateFromLinkQualityZeroLossStaysReasonable() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.0, etx: 1.0, srtt: 0.5)
        XCTAssertGreaterThanOrEqual(settings.windowSize.currentAdaptive, 1)
        XCTAssertLessThanOrEqual(settings.windowSize.currentAdaptive, 7)
        XCTAssertGreaterThanOrEqual(settings.paclen.currentAdaptive, 32)
        XCTAssertLessThanOrEqual(settings.paclen.currentAdaptive, 256)
    }

    func testUpdateFromLinkQualityNilSrttDoesNotCrash() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.2, etx: 2.0, srtt: nil)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 1)
        XCTAssertEqual(settings.paclen.currentAdaptive, 64)
    }

    func testUpdateFromLinkQualityExtremeLossClampsWindowToOne() {
        var settings = TxAdaptiveSettings()
        settings.updateFromLinkQuality(lossRate: 0.9, etx: 20.0, srtt: nil)
        XCTAssertEqual(settings.windowSize.currentAdaptive, 1)
        XCTAssertLessThanOrEqual(settings.paclen.currentAdaptive, 64)
    }

    func testUpdateFromLinkQualityGoodLinkIncreasesWindow() {
        var settings = TxAdaptiveSettings()
        settings.windowSize.currentAdaptive = 1
        settings.updateFromLinkQuality(lossRate: 0.02, etx: 1.05, srtt: 1.0)
        XCTAssertGreaterThanOrEqual(settings.windowSize.currentAdaptive, 2)
    }
}
