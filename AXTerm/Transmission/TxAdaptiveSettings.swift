//
//  TxAdaptiveSettings.swift
//  AXTerm
//
//  Adaptive parameter settings with Auto/Manual mode per parameter.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 4.1
//
//  Settings UX requirement (from spec):
//  - Mode: Auto / Manual per parameter
//  - If Manual: value picker enabled
//  - If Auto: show "Current" + "Suggested" + "Reason"
//

import Foundation

// MARK: - Adaptive Mode

/// Mode for an adaptive parameter
enum AdaptiveMode: String, Sendable, CaseIterable {
    case auto
    case manual
}

// MARK: - Adaptive Setting

/// Generic adaptive setting with Auto/Manual mode
struct AdaptiveSetting<T: Comparable & Sendable>: Sendable {
    /// Internal name for persistence
    let name: String

    /// Display name for UI
    let displayName: String

    /// Default value
    let defaultValue: T

    /// Valid range (for numeric types)
    let range: ClosedRange<T>?

    /// Current mode
    var mode: AdaptiveMode = .auto

    /// Manual override value
    var manualValue: T

    /// Current value from adaptive algorithm
    var currentAdaptive: T

    /// Reason for current adaptive value
    var adaptiveReason: String?

    init(name: String, displayName: String, defaultValue: T, range: ClosedRange<T>? = nil) {
        self.name = name
        self.displayName = displayName
        self.defaultValue = defaultValue
        self.range = range
        self.manualValue = defaultValue
        self.currentAdaptive = defaultValue
    }

    /// Effective value based on current mode
    var effectiveValue: T {
        switch mode {
        case .auto:
            return currentAdaptive
        case .manual:
            return clampedManualValue
        }
    }

    /// Manual value clamped to valid range
    var clampedManualValue: T {
        guard let range = range else { return manualValue }
        return min(max(manualValue, range.lowerBound), range.upperBound)
    }

    /// Reason to display (only in auto mode)
    var displayReason: String? {
        guard mode == .auto else { return nil }
        return adaptiveReason
    }
}

// MARK: - TX Adaptive Settings

/// All adaptive parameters for transmission
struct TxAdaptiveSettings: Sendable {

    // MARK: - Traffic Shaping Parameters (Section 4)

    /// Packet length (bytes)
    var paclen = AdaptiveSetting<Int>(
        name: "paclen",
        displayName: "Packet Length",
        defaultValue: 128,
        range: 32...256
    )

    /// Window size (K - outstanding frames)
    var windowSize = AdaptiveSetting<Int>(
        name: "windowSize",
        displayName: "Window Size",
        defaultValue: 2,
        range: 1...7
    )

    /// Maximum retry attempts (N2)
    var maxRetries = AdaptiveSetting<Int>(
        name: "maxRetries",
        displayName: "Max Retries",
        defaultValue: 10,
        range: 1...20
    )

    /// Minimum RTO (seconds)
    var rtoMin = AdaptiveSetting<Double>(
        name: "rtoMin",
        displayName: "Min RTO",
        defaultValue: 1.0,
        range: 0.5...5.0
    )

    /// Maximum RTO (seconds)
    var rtoMax = AdaptiveSetting<Double>(
        name: "rtoMax",
        displayName: "Max RTO",
        defaultValue: 30.0,
        range: 5.0...60.0
    )

    // MARK: - AXDP Settings (Section 6.x)

    /// AXDP protocol version to use
    var axdpVersion: UInt8 = AXDP.version

    /// Enable AXDP extensions
    var axdpExtensionsEnabled: Bool = true

    /// Auto-negotiate capabilities with peers
    // Default off to avoid sending binary AXDP PINGs to legacy nodes/BBS.
    var autoNegotiateCapabilities: Bool = false

    /// Enable compression for AXDP transfers
    var compressionEnabled: Bool = true

    /// Preferred compression algorithm
    var compressionAlgorithm: AXDPCompression.Algorithm = .lz4

    /// Maximum decompressed payload size
    var maxDecompressedPayload: UInt32 = 4096

    /// Max decompressed clamped to absolute limit
    var clampedMaxDecompressedPayload: UInt32 {
        min(maxDecompressedPayload, AXDPCompression.absoluteMaxDecompressedLen)
    }

    // MARK: - Debug Settings

    /// Show AXDP decode details in transcript
    var showAXDPDecodeDetails: Bool = false

    // MARK: - Initialization

    init() {}

    // MARK: - Convenience

    /// Get all adaptive settings as array for iteration
    var allAdaptiveSettings: [Any] {
        [paclen, windowSize, maxRetries, rtoMin, rtoMax]
    }

    /// Update adaptive values from link quality
    mutating func updateFromLinkQuality(
        lossRate: Double,
        etx: Double,
        srtt: Double?
    ) {
        // Paclen adaptation (per spec Section 4.2)
        if lossRate > 0.2 || etx > 2.0 {
            paclen.currentAdaptive = 64
            paclen.adaptiveReason = "Loss \(Int(lossRate * 100))%, ETX \(String(format: "%.1f", etx))"
        } else if lossRate > 0.1 {
            paclen.currentAdaptive = min(paclen.currentAdaptive, 128)
            paclen.adaptiveReason = "Moderate loss (\(Int(lossRate * 100))%)"
        } else {
            paclen.currentAdaptive = paclen.defaultValue
            paclen.adaptiveReason = "Link stable"
        }

        // Window size adaptation (per spec Section 4.4)
        if lossRate > 0.2 {
            windowSize.currentAdaptive = 1
            windowSize.adaptiveReason = "High loss - stop-and-wait"
        } else if etx < 1.5 {
            windowSize.currentAdaptive = min(4, windowSize.defaultValue + 1)
            windowSize.adaptiveReason = "Good link quality"
        } else {
            windowSize.currentAdaptive = windowSize.defaultValue
            windowSize.adaptiveReason = nil
        }

        // RTO from SRTT (per spec Section 7.3)
        if let rtt = srtt {
            // RTO = SRTT + 4 * RTTVAR (simplified: use 2x SRTT as rough estimate)
            let suggestedRto = rtt * 2.0
            let clampedRto = max(rtoMin.effectiveValue, min(rtoMax.effectiveValue, suggestedRto))
            rtoMin.adaptiveReason = "Based on measured RTT \(String(format: "%.1f", rtt))s"
            rtoMax.adaptiveReason = "Suggested RTO: \(String(format: "%.1f", clampedRto))s"
        }
    }
}
