//
//  AX25FrameType.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

/// AX.25 frame types
enum FrameType: String, Hashable, Codable, CaseIterable {
    case ui = "UI"      // Unnumbered Information
    case i = "I"        // Information
    case s = "S"        // Supervisory
    case u = "U"        // Unnumbered (other than UI)
    case unknown = "?"

    var displayName: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .ui: return "📡"
        case .i: return "💬"
        case .s: return "🔁"
        case .u: return "⚙️"
        case .unknown: return "❓"
        }
    }
}
