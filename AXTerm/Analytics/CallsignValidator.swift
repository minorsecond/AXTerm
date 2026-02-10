//
//  CallsignValidator.swift
//  AXTerm
//
//  Validates amateur radio callsigns and extracts suffix labels for graph display.
//

import Foundation

/// Validates and parses amateur radio callsigns.
/// Filters out non-callsign entities like BEACON, ID, WIDE1-1, etc.
nonisolated enum CallsignValidator {

    // MARK: - Basic Validation (used by Settings)

    /// Basic callsign pattern for user input validation
    nonisolated static let callsignPattern = "^[A-Z0-9]{1,6}(?:-[0-9]{1,2})?$"

    /// Normalizes a callsign string (trims whitespace and uppercases)
    nonisolated static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Basic validation for user-entered callsigns (less strict than isValidCallsign)
    nonisolated static func isValid(_ value: String) -> Bool {
        let normalized = normalize(value)
        guard !normalized.isEmpty else { return false }
        guard normalized.rangeOfCharacter(from: .letters) != nil else { return false }
        return normalized.range(of: callsignPattern, options: [.regularExpression]) != nil
    }

    // MARK: - Known Non-Callsign Patterns

    /// Special APRS/AX.25 destinations and pseudo-callsigns to exclude
    private static let nonCallsignPatterns: Set<String> = [
        "ID", "BEACON", "MAIL", "QST", "CQ", "SK", "TEST", "RELAY",
        "GATE", "ECHO", "TEMP", "TRACE", "ALL", "AP", "BLN", "NWS",
        "APRS", "GPS", "DGPS", "TCPIP", "TCPXX", "NOGATE", "RFONLY",
        "IGATE", "APRSD", "APRSM", "APRST", "APRSW", "SPCL", "DF",
        "DRILL", "DX", "JAVA", "MAIL", "MICE", "SPACE", "SPC", "SYM",
        "TEL", "TELEMETRY", "WX", "WXSVR"
    ]

    /// Prefixes that indicate non-callsign entities
    private static let nonCallsignPrefixes: [String] = [
        "WIDE", "TRACE", "RELAY", "BLN", "NWS", "APRS"
    ]

    // MARK: - Validation

    /// Checks if a string represents a valid amateur radio callsign.
    /// Returns false for known non-callsign entities like BEACON, WIDE1-1, etc.
    static func isValidCallsign(_ candidate: String) -> Bool {
        let upper = candidate.uppercased()

        // Remove SSID for validation
        let baseCall = upper.components(separatedBy: "-").first ?? upper

        // Check against known non-callsign patterns
        if nonCallsignPatterns.contains(baseCall) {
            return false
        }

        // Check against prefixes (WIDE1, WIDE2, etc.)
        for prefix in nonCallsignPrefixes {
            if baseCall.hasPrefix(prefix) && baseCall.count <= prefix.count + 2 {
                return false
            }
        }

        // Basic callsign structure validation:
        // Amateur callsigns typically have 1-2 letter prefix, 1 digit, and 1-3 letter suffix
        // Examples: W5ABC, N0CALL, VK3XYZ, G4ABC, JA1XYZ

        // Must be at least 3 characters (e.g., W1A)
        guard baseCall.count >= 3 && baseCall.count <= 7 else {
            return false
        }

        // Must contain at least one digit and at least one letter
        let hasDigit = baseCall.contains(where: { $0.isNumber })
        let hasLetter = baseCall.contains(where: { $0.isLetter })

        guard hasDigit && hasLetter else {
            return false
        }

        // Check for valid callsign pattern: letters, then digit(s), then letters
        // This catches most amateur callsigns while rejecting things like "123ABC"
        let pattern = #"^[A-Z]{1,2}[0-9]{1,2}[A-Z]{1,4}$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(baseCall.startIndex..., in: baseCall)

        if regex?.firstMatch(in: baseCall, options: [], range: range) != nil {
            return true
        }

        // Also allow reverse pattern for some international calls (e.g., 3DA0XYZ)
        let reversePattern = #"^[0-9][A-Z]{1,2}[0-9]?[A-Z]{1,4}$"#
        let reverseRegex = try? NSRegularExpression(pattern: reversePattern, options: [])

        return reverseRegex?.firstMatch(in: baseCall, options: [], range: range) != nil
    }

    // MARK: - Suffix Extraction

    /// Extracts a short suffix label from a callsign for graph display.
    /// Examples:
    /// - "K0EPI-7" -> "EPI-7"
    /// - "WH6ANH" -> "ANH"
    /// - "N0CALL" -> "CALL"
    /// - "W1AW" -> "AW"
    static func extractSuffix(_ callsign: String) -> String {
        let upper = callsign.uppercased()

        // Split into base call and SSID
        let parts = upper.components(separatedBy: "-")
        let baseCall = parts[0]
        let ssid = parts.count > 1 ? parts[1] : nil

        // Find the numeric portion (call area digit)
        // The suffix is everything after the last digit
        var lastDigitIndex: String.Index?
        for (index, char) in baseCall.enumerated() {
            if char.isNumber {
                lastDigitIndex = baseCall.index(baseCall.startIndex, offsetBy: index)
            }
        }

        let suffix: String
        if let lastDigitIdx = lastDigitIndex {
            let afterDigit = baseCall.index(after: lastDigitIdx)
            if afterDigit < baseCall.endIndex {
                suffix = String(baseCall[afterDigit...])
            } else {
                // No suffix letters, use last 2-3 chars of call
                suffix = String(baseCall.suffix(min(3, baseCall.count)))
            }
        } else {
            // No digit found, use last 3 characters
            suffix = String(baseCall.suffix(min(3, baseCall.count)))
        }

        // Append SSID if present
        if let ssid = ssid, !ssid.isEmpty {
            return "\(suffix)-\(ssid)"
        }

        return suffix
    }
}
