//
//  ConsoleTheme.swift
//  AXTerm
//
//  Centralized theme configuration for console message styling
//

import SwiftUI

/// Central configuration for console message emphasis colors and opacities
/// Tuned for premium appearance in both light and dark modes
struct ConsoleTheme {
    
    // MARK: - System Message Emphasis
    
    /// Background opacity for system messages - tuned for dark mode visibility
    static let systemBackgroundOpacity: Double = 0.08
    
    /// Indicator bar opacity for system messages - more prominent than background
    static let systemIndicatorOpacity: Double = 0.7
    
    // MARK: - Error Message Emphasis
    
    /// Background opacity for error messages - more prominent than system
    static let errorBackgroundOpacity: Double = 0.12
    
    /// Indicator bar opacity for error messages - strong but not harsh
    static let errorIndicatorOpacity: Double = 0.85
    
    // MARK: - Warning Message Emphasis (future-proof)
    
    /// Background opacity for warning messages
    static let warningBackgroundOpacity: Double = 0.10
    
    /// Indicator bar opacity for warning messages
    static let warningIndicatorOpacity: Double = 0.75
    
    // MARK: - Layout Constants
    
    /// Width of leading indicator bars
    static let indicatorBarWidth: CGFloat = 3
    
    /// Corner radius for row backgrounds
    static let rowCornerRadius: CGFloat = 4
    
    /// Standard padding for emphasized rows
    static let rowPadding: CGFloat = 4
    
    // MARK: - Color Helpers
    
    /// Returns the appropriate background color for a message kind
    static func backgroundColor(for kind: ConsoleLine.Kind) -> Color {
        switch kind {
        case .system:
            return Color.gray.opacity(systemBackgroundOpacity)
        case .error:
            return Color.red.opacity(errorBackgroundOpacity)
        case .packet:
            return .clear
        }
    }
    
    /// Returns the appropriate indicator bar color for a message kind
    static func indicatorColor(for kind: ConsoleLine.Kind) -> Color {
        switch kind {
        case .system:
            return Color.gray.opacity(systemIndicatorOpacity)
        case .error:
            return Color.red.opacity(errorIndicatorOpacity)
        case .packet:
            return .gray  // Fallback for packets
        }
    }
}