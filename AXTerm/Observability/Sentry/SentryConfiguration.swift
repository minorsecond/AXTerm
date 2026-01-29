//
//  SentryConfiguration.swift
//  AXTerm
//
//  Created by AXTerm on 2026-01-29.
//

import Foundation

/// Configuration for Sentry SDK initialization.
///
/// Values are loaded from Info.plist (populated from xcconfig) and user settings.
/// The xcconfig files define build-specific values (Debug vs Release).
struct SentryConfiguration: Equatable, Sendable {
    // MARK: - Info.plist Keys

    static let infoPlistDSNKey = "SentryDSN"
    static let infoPlistEnvironmentKey = "SentryEnvironment"
    static let infoPlistDebugKey = "SentryDebug"
    static let infoPlistTracesSampleRateKey = "SentryTracesSampleRate"
    static let infoPlistProfilesSampleRateKey = "SentryProfilesSampleRate"

    /// Environment variable fallback for DSN (useful for CI or local overrides).
    static let environmentVariableDSNKey = "SENTRY_DSN"

    // MARK: - Configuration Properties

    /// Sentry DSN. `nil` means Sentry is not configured.
    let dsn: String?

    /// Environment tag (e.g., "development", "production").
    let environment: String

    /// Whether Sentry debug logging is enabled.
    let debug: Bool

    /// Sample rate for performance traces (0.0 to 1.0).
    let tracesSampleRate: Double

    /// Sample rate for continuous profiling (0.0 to 1.0).
    let profilesSampleRate: Double

    /// Release identifier in format: `AXTerm@<version>+<build>`.
    let release: String

    /// Distribution identifier (build number).
    let dist: String

    /// User preference: whether Sentry is enabled at all.
    let enabledByUser: Bool

    /// User preference: whether to include packet contents in telemetry.
    let sendPacketContents: Bool

    /// User preference: whether to include connection details in telemetry.
    let sendConnectionDetails: Bool

    // MARK: - Computed Properties

    /// Whether Sentry should actually start (DSN present AND user enabled).
    var shouldStart: Bool {
        dsn != nil && enabledByUser
    }

    // MARK: - Loading

    /// Load configuration from Info.plist, environment variables, and user settings.
    ///
    /// - Parameters:
    ///   - bundle: Bundle to read Info.plist from (default: `.main`).
    ///   - environmentVariables: Environment variables for DSN fallback.
    ///   - settings: User settings store (can be nil for testing).
    /// - Returns: Fully populated configuration.
    @MainActor
    static func load(
        bundle: Bundle = .main,
        environmentVariables: [String: String] = ProcessInfo.processInfo.environment,
        settings: AppSettingsStore
    ) -> SentryConfiguration {
        load(
            infoPlist: InfoPlistReader(bundle: bundle),
            environmentVariables: environmentVariables,
            enabledByUser: settings.sentryEnabled,
            sendPacketContents: settings.sentrySendPacketContents,
            sendConnectionDetails: settings.sentrySendConnectionDetails
        )
    }

    /// Load configuration from an injectable Info.plist reader (for testing).
    static func load(
        infoPlist: InfoPlistReading,
        environmentVariables: [String: String] = [:],
        enabledByUser: Bool = true,
        sendPacketContents: Bool = false,
        sendConnectionDetails: Bool = false
    ) -> SentryConfiguration {
        let dsn = resolveDSN(
            environmentValue: environmentVariables[environmentVariableDSNKey],
            infoPlistValue: infoPlist.string(forKey: infoPlistDSNKey)
        )

        let environment = infoPlist.string(forKey: infoPlistEnvironmentKey) ?? "unknown"
        let debug = infoPlist.bool(forKey: infoPlistDebugKey)
        let tracesSampleRate = infoPlist.double(forKey: infoPlistTracesSampleRateKey) ?? 0.0
        let profilesSampleRate = infoPlist.double(forKey: infoPlistProfilesSampleRateKey) ?? 0.0

        let version = infoPlist.string(forKey: "CFBundleShortVersionString") ?? "0"
        let build = infoPlist.string(forKey: "CFBundleVersion") ?? "0"
        let name = infoPlist.string(forKey: "CFBundleName") ?? "AXTerm"

        return SentryConfiguration(
            dsn: dsn,
            environment: environment,
            debug: debug,
            tracesSampleRate: clampSampleRate(tracesSampleRate),
            profilesSampleRate: clampSampleRate(profilesSampleRate),
            release: "\(name)@\(version)+\(build)",
            dist: build,
            enabledByUser: enabledByUser,
            sendPacketContents: sendPacketContents,
            sendConnectionDetails: sendConnectionDetails
        )
    }

    // MARK: - DSN Resolution

    /// Resolve DSN from environment variable (priority) or Info.plist.
    static func resolveDSN(environmentValue: String?, infoPlistValue: String?) -> String? {
        if let env = sanitizeValue(environmentValue), !env.isEmpty {
            return env
        }
        return sanitizeValue(infoPlistValue)
    }

    // MARK: - Private Helpers

    private static func sanitizeValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clampSampleRate(_ rate: Double) -> Double {
        min(max(rate, 0.0), 1.0)
    }
}

// MARK: - Info.plist Reading Protocol

/// Protocol for reading Info.plist values, enabling dependency injection for tests.
protocol InfoPlistReading: Sendable {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func double(forKey key: String) -> Double?
}

/// Default implementation that reads from a Bundle's Info.plist.
struct InfoPlistReader: InfoPlistReading {
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func string(forKey key: String) -> String? {
        bundle.object(forInfoDictionaryKey: key) as? String
    }

    func bool(forKey key: String) -> Bool {
        // Info.plist stores booleans as strings "YES"/"NO" when from xcconfig.
        guard let value = bundle.object(forInfoDictionaryKey: key) else { return false }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let stringValue = value as? String {
            return stringValue.uppercased() == "YES" || stringValue == "1" || stringValue.uppercased() == "TRUE"
        }
        return false
    }

    func double(forKey key: String) -> Double? {
        guard let value = bundle.object(forInfoDictionaryKey: key) else { return nil }
        if let doubleValue = value as? Double {
            return doubleValue
        }
        if let stringValue = value as? String {
            return Double(stringValue)
        }
        if let numberValue = value as? NSNumber {
            return numberValue.doubleValue
        }
        return nil
    }
}

/// Mock Info.plist reader for testing.
struct MockInfoPlistReader: InfoPlistReading {
    var values: [String: Any]

    init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func bool(forKey key: String) -> Bool {
        if let boolValue = values[key] as? Bool {
            return boolValue
        }
        if let stringValue = values[key] as? String {
            return stringValue.uppercased() == "YES" || stringValue == "1" || stringValue.uppercased() == "TRUE"
        }
        return false
    }

    func double(forKey key: String) -> Double? {
        if let doubleValue = values[key] as? Double {
            return doubleValue
        }
        if let stringValue = values[key] as? String {
            return Double(stringValue)
        }
        return nil
    }
}

