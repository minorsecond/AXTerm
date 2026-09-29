//
//  WireDebugSettings.swift
//  AXTerm
//
//  Debug-only gate for verbose wire logging and diagnostics.
//

import Foundation

nonisolated enum WireDebugSettings {
    static let envKey = "AXTERM_WIRE_DEBUG"
    static let defaultsKey = "AXTermWireDebug"

    static var isEnabled: Bool {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment[envKey]?.lowercased() {
            return value == "1" || value == "true" || value == "yes"
        }
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        return true
        #else
        return false
        #endif
    }
}
