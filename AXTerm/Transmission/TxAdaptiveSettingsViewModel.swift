//
//  TxAdaptiveSettingsViewModel.swift
//  AXTerm
//
//  View model for adaptive transmission settings.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 4.1
//
//  Settings UX requirement (from spec):
//  - Mode: Auto / Manual per parameter
//  - If Manual: value picker enabled
//  - If Auto: show "Current" + "Suggested" + "Reason"
//

import Foundation
import Combine

/// View model for TxAdaptiveSettings UI
nonisolated struct TxAdaptiveSettingsViewModel: Sendable {

    /// The settings being edited
    var settings: TxAdaptiveSettings

    // MARK: - Initialization

    init(settings: TxAdaptiveSettings = TxAdaptiveSettings()) {
        self.settings = settings
    }

    // MARK: - Mode Toggle

    /// Toggle mode for an Int adaptive setting
    mutating func toggleMode<T: Comparable & Sendable>(for keyPath: WritableKeyPath<TxAdaptiveSettings, AdaptiveSetting<T>>) {
        let current = settings[keyPath: keyPath].mode
        settings[keyPath: keyPath].mode = (current == .auto) ? .manual : .auto
    }

    // MARK: - Manual Value Setting

    /// Set manual value for an Int adaptive setting
    mutating func setManualValue(_ value: Int, for keyPath: WritableKeyPath<TxAdaptiveSettings, AdaptiveSetting<Int>>) {
        settings[keyPath: keyPath].manualValue = value
    }

    /// Set manual value for a Double adaptive setting
    mutating func setManualDoubleValue(_ value: Double, for keyPath: WritableKeyPath<TxAdaptiveSettings, AdaptiveSetting<Double>>) {
        settings[keyPath: keyPath].manualValue = value
    }

    // MARK: - Display Helpers

    /// Get display reason for an adaptive setting (nil if in manual mode)
    func displayReason<T: Comparable & Sendable>(for keyPath: KeyPath<TxAdaptiveSettings, AdaptiveSetting<T>>) -> String? {
        settings[keyPath: keyPath].displayReason
    }

    /// Check if setting is in manual mode
    func isManualMode<T: Comparable & Sendable>(for keyPath: KeyPath<TxAdaptiveSettings, AdaptiveSetting<T>>) -> Bool {
        settings[keyPath: keyPath].mode == .manual
    }

    // MARK: - Reset

    /// Reset all settings to defaults
    mutating func resetToDefaults() {
        settings = TxAdaptiveSettings()
    }

    // MARK: - Link Quality Updates

    /// Update adaptive values based on link quality metrics
    mutating func updateFromLinkQuality(lossRate: Double, etx: Double, srtt: Double?) {
        settings.updateFromLinkQuality(lossRate: lossRate, etx: etx, srtt: srtt)
    }
}
