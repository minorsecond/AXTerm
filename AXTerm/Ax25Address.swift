//
//  Ax25Address.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

/// Represents an AX.25 address (callsign + SSID)
struct AX25Address: Hashable, Codable, Identifiable {
    let call: String
    let ssid: Int
    let repeated: Bool

    var id: String { display }

    var display: String {
        ssid > 0 ? "\(call)-\(ssid)" : call
    }

    init(call: String, ssid: Int = 0, repeated: Bool = false) {
        // Normalize: trim whitespace and uppercase
        self.call = call.trimmingCharacters(in: .whitespaces).uppercased()
        self.ssid = max(0, min(15, ssid))
        self.repeated = repeated
    }
}
