//
//  Callsign.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/8/26.
//

import Foundation

/// A validated, normalized AX.25 callsign with optional SSID.
struct Callsign: Equatable, Hashable, Codable, CustomStringConvertible, Sendable {
    /// The base callsign (e.g., "K0EPI")
    let base: String
    
    /// The SSID (0-15). 0 implies no SSID suffix.
    let ssid: Int
    
    /// Returns the standard string representation (e.g., "K0EPI" or "K0EPI-7").
    var description: String {
        stringValue
    }
    
    /// Returns the standard string representation used for display and transmission.
    /// SSID 0 is omitted (e.g. "K0EPI-0" -> "K0EPI").
    var stringValue: String {
        ssid == 0 ? base : "\(base)-\(ssid)"
    }
    
    /// Initializes a Callsign from a string, normalizing it.
    /// - Parameter string: Input string (e.g., "k0epi-7", "K0EPI", "  K0EPI-07  ")
    /// - Returns: A normalized Callsign, or nil if invalid.
    init?(_ string: String) {
        let normalized = CallsignValidator.normalize(string)
        guard !normalized.isEmpty else { return nil }
        
        let parts = normalized.split(separator: "-")
        guard !parts.isEmpty else { return nil }
        
        self.base = String(parts[0])
        
        if parts.count > 1, let ssidVal = Int(parts[1]) {
            self.ssid = max(0, min(15, ssidVal)) // Clamp to 0-15
        } else {
            self.ssid = 0
        }
        
        // Basic validation: Base must have digits/letters
        // We use the existing validator logic for robustness
        guard CallsignValidator.isValidCallsign(self.stringValue) else {
            // Allow slightly relaxed parsing for UI entry, but strict for final object?
            // Actually CallsignValidator.isValidCallsign is strict.
            // Let's rely on basic sanity check here so we can represent "in-progress" typing
            // if needed, but for a model type, we should probably enforce validity.
            // Retaining stricter validation to ensure model integrity.
            return nil
        }
    }
    
    /// Creates a Callsign from components.
    init(base: String, ssid: Int = 0) {
        self.base = base.uppercased()
        self.ssid = max(0, min(15, ssid))
    }
}
