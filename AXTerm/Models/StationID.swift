//
//  StationID.swift
//  AXTerm
//
//  Created by Antigravity on 2/9/26.
//

import Foundation

/// Unique identifier for a station, comprising a normalized callsign and an SSID (0-15).
/// "CALL" and "CALL-0" are normalized identically.
struct StationID: Hashable, Codable, Identifiable, Sendable {
    let call: String
    let ssid: Int

    var id: String { display }

    var display: String {
        ssid > 0 ? "\(call)-\(ssid)" : call
    }

    /// Initializes a StationID from a string like "K0NTS-7" or "K0NTS".
    /// Normalizes callsign to uppercase and maps no-SSID/-0 to 0.
    init(_ callsign: String) {
        let (call, ssid) = CallsignNormalizer.parse(callsign)
        self.call = call.uppercased()
        self.ssid = ssid
    }

    /// Initializes from explicit call and SSID components.
    init(call: String, ssid: Int = 0) {
        self.call = call.uppercased().trimmingCharacters(in: .whitespaces)
        self.ssid = max(0, min(15, ssid))
    }
}

extension StationID: CustomStringConvertible {
    var description: String { display }
}
