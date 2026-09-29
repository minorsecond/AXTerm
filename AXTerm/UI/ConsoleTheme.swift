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

    /// The accent for an error or connection-failure line. A muted amber, not a
    /// loud red: these lines are frequent and mostly transient (a radio dropped,
    /// a reconnect), so they should be findable at a glance without turning the
    /// log into a wall of alarm. The row text itself stays neutral; only this
    /// thin cue carries the colour.
    static let errorAccent: Color = Color.orange.opacity(0.85)

    /// Background opacity for error messages. Kept level with system lines so an
    /// error reads as calm status, not an emergency.
    static let errorBackgroundOpacity: Double = 0.08

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
    /// Gap between rows in the console list. Named because the timestamp
    /// run connector has to bridge it: the line is drawn per row, so a row
    /// that does not reach into the gap leaves a break in what should read as
    /// one continuous thread.
    static let rowSpacing: CGFloat = 2

    /// How far to fade a timestamp that repeats the row above it.
    ///
    /// Low enough that a run reads as one block at a glance, high enough
    /// that the digits are still legible when an operator wants to check a
    /// single row rather than trace it back to the top of its run.
    static let repeatedTimestampOpacity: Double = 0.3
    
    // MARK: - Color Helpers
    
    /// Returns the appropriate background color for a message kind
    static func backgroundColor(for kind: ConsoleLine.Kind) -> Color {
        switch kind {
        case .system:
            return Color.gray.opacity(systemBackgroundOpacity)
        case .error:
            return Color.gray.opacity(errorBackgroundOpacity)
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
            return errorAccent
        case .packet:
            return .gray  // Fallback for packets
        }
    }
}