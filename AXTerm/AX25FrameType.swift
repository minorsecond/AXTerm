//
//  AX25FrameType.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import Foundation

/// AX.25 frame types
nonisolated enum FrameType: String, Hashable, Codable, CaseIterable {
    case ui = "UI"      // Unnumbered Information
    case i = "I"        // Information
    case s = "S"        // Supervisory
    case u = "U"        // Unnumbered (other than UI)
    case unknown = "?"

    var displayName: String {
        rawValue
    }

    var shortLabel: String {
        rawValue
    }

    var helpText: String {
        switch self {
        case .ui:
            return "UI-frame (unnumbered information payload)"
        case .i:
            return "I-frame (user data)"
        case .s:
            return "S-frame (supervisory control)"
        case .u:
            return "U-frame (unnumbered control)"
        case .unknown:
            return "Unknown frame type"
        }
    }
}
