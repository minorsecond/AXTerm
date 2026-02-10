//
//  TestModeConfiguration.swift
//  AXTerm
//
//  Command-line argument parsing for test mode.
//  Allows launching multiple AXTerm instances with different configurations.
//
//  Usage:
//    AXTerm --test-mode --port 8001 --callsign TEST1 --instance-name "Station A"
//    AXTerm --test-mode --port 8002 --callsign TEST2 --instance-name "Station B"
//

import Foundation

/// Parses command-line arguments for test mode configuration.
/// When running in test mode, these settings override UserDefaults.
nonisolated struct TestModeConfiguration {
    /// Whether the app is running in test mode
    let isTestMode: Bool

    /// Override port for KISS connection
    let port: UInt16?

    /// Override callsign
    let callsign: String?

    /// Instance name for window title (e.g., "Station A")
    let instanceName: String?

    /// Auto-connect on launch in test mode
    let autoConnect: Bool

    /// Host to connect to
    let host: String?

    /// Disable database persistence in test mode
    let ephemeralDatabase: Bool

    /// Shared singleton for easy access
    static let shared = TestModeConfiguration()

    private init() {
        let args = ProcessInfo.processInfo.arguments

        self.isTestMode = args.contains("--test-mode")

        // Parse --port <value>
        if let portIndex = args.firstIndex(of: "--port"),
           portIndex + 1 < args.count,
           let portValue = UInt16(args[portIndex + 1]) {
            self.port = portValue
        } else {
            self.port = nil
        }

        // Parse --callsign <value>
        if let callsignIndex = args.firstIndex(of: "--callsign"),
           callsignIndex + 1 < args.count {
            self.callsign = args[callsignIndex + 1]
        } else {
            self.callsign = nil
        }

        // Parse --instance-name <value>
        if let nameIndex = args.firstIndex(of: "--instance-name"),
           nameIndex + 1 < args.count {
            self.instanceName = args[nameIndex + 1]
        } else {
            self.instanceName = nil
        }

        // Parse --host <value>
        if let hostIndex = args.firstIndex(of: "--host"),
           hostIndex + 1 < args.count {
            self.host = args[hostIndex + 1]
        } else {
            self.host = nil
        }

        // Parse flags
        self.autoConnect = args.contains("--auto-connect")
        self.ephemeralDatabase = args.contains("--ephemeral-db")
    }

    /// Returns the effective port, using override if in test mode, otherwise the provided default
    func effectivePort(default defaultPort: UInt16) -> UInt16 {
        if isTestMode, let port = port {
            return port
        }
        return defaultPort
    }

    /// Returns the effective host, using override if in test mode, otherwise the provided default
    func effectiveHost(default defaultHost: String) -> String {
        if isTestMode, let host = host {
            return host
        }
        return defaultHost
    }

    /// Returns the effective callsign, using override if in test mode, otherwise the provided default
    func effectiveCallsign(default defaultCallsign: String) -> String {
        if isTestMode, let callsign = callsign {
            return callsign
        }
        return defaultCallsign
    }

    /// Window title modifier for test mode
    var windowTitleSuffix: String {
        if isTestMode, let name = instanceName {
            return " - \(name)"
        }
        return ""
    }

    /// Unique identifier for this test instance (used for ephemeral database naming)
    var instanceID: String {
        if let name = instanceName {
            return name
        }
        if let port = port {
            return "port-\(port)"
        }
        if let callsign = callsign {
            return callsign
        }
        return "default"
    }
}
