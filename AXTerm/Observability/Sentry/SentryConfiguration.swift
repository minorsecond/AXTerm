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
nonisolated struct SentryConfiguration: Equatable, Sendable {
    // MARK: - Info.plist Keys

    static let infoPlistDSNKey = "SENTRY_DSN"
    static let infoPlistEnvironmentKey = "SENTRY_ENVIRONMENT"
    static let infoPlistDebugKey = "SENTRY_DEBUG"
    static let infoPlistTracesSampleRateKey = "SENTRY_TRACES_SAMPLE_RATE"
    static let infoPlistProfilesSampleRateKey = "SENTRY_PROFILES_SAMPLE_RATE"
    static let legacyInfoPlistProfilesSampleRateKey = "sentry_profiles_sample_rate"
    static let generatedInfoPlistProfilesSampleRateKey = "SentryProfilesSampleRate"
    static let infoPlistGitCommitKey = "SENTRY_GIT_COMMIT"

    /// Environment variable fallback for DSN (useful for CI or local overrides).
    static let environmentVariableDSNKey = "SENTRY_DSN"
    static let environmentVariableGitCommitKeys = ["SENTRY_GIT_COMMIT", "GIT_COMMIT_HASH", "GITHUB_SHA", "CI_COMMIT_SHA"]

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

    /// Git commit hash associated with this build (if available).
    let gitCommit: String?

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
        let profilesSampleRate = resolveProfilesSampleRate(infoPlist: infoPlist)
        let gitCommit = resolveGitCommit(
            infoPlistValue: infoPlist.string(forKey: infoPlistGitCommitKey),
            environmentVariables: environmentVariables
        )

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
            gitCommit: gitCommit,
            enabledByUser: enabledByUser,
            sendPacketContents: sendPacketContents,
            sendConnectionDetails: sendConnectionDetails
        )
    }

    // MARK: - DSN Resolution

    /// Resolve DSN from environment variable (priority) or Info.plist.
    static func resolveDSN(environmentValue: String?, infoPlistValue: String?) -> String? {
        if let envRaw = environmentValue, let env = sanitizeDSNValue(envRaw) {
            return env
        }
        if let plistRaw = infoPlistValue, let plist = sanitizeDSNValue(plistRaw) {
            return plist
        }
        return nil
    }

    static func resolveGitCommit(infoPlistValue: String?, environmentVariables: [String: String]) -> String? {
        for key in environmentVariableGitCommitKeys {
            if let value = sanitizeGitCommit(environmentVariables[key]) {
                return value
            }
        }
        if let value = sanitizeGitCommit(infoPlistValue) {
            return value
        }
        if let value = readGitCommitFromRepository() {
            return value
        }
        return nil
    }

    // MARK: - Private Helpers
    
    /// Sanitize and validate DSN-ish strings coming from xcconfig/Info.plist/env.
    /// Returns nil if empty after sanitization.
    private static func sanitizeDSNValue(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // If Xcode injected quotes into the plist value, strip them.
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // xcconfig hack you used: https:$(/)$(/)... becomes https:////...
        // Normalize any "http(s):" followed by 2+ slashes to exactly "://"
        if s.hasPrefix("https:") {
            s = "https:" + s.dropFirst("https:".count)
        } else if s.hasPrefix("http:") {
            s = "http:" + s.dropFirst("http:".count)
        }

        // Collapse backslash escapes like https:\/\/... into https://...
        s = s.replacingOccurrences(of: #"\\/"#, with: "/", options: .regularExpression)

        // Now fix the common missing-double-slash case: "https:8714..." -> "https://8714..."
        if s.hasPrefix("https:") && !s.hasPrefix("https://") {
            s = s.replacingOccurrences(of: "https:", with: "https://")
        }
        if s.hasPrefix("http:") && !s.hasPrefix("http://") {
            s = s.replacingOccurrences(of: "http:", with: "http://")
        }

        // Fix the other common broken case you *actually have*:
        // "...ingest.us.sentry.io451079..." -> "...ingest.us.sentry.io/451079..."
        // Only do this if there's no slash after the host already.
        if let atIdx = s.firstIndex(of: "@") {
            let afterAt = s[s.index(after: atIdx)...]
            if !afterAt.contains("/") {
                // Insert a slash right after ".io" (works for sentry.io + ingest.us.sentry.io)
                s = s.replacingOccurrences(of: ".io", with: ".io/")
            } else {
                // There IS a slash after @ somewhere; but your broken string can still be missing the slash
                // specifically between ".io" and the project id. Only patch ".io<digits>" -> ".io/<digits>"
                s = s.replacingOccurrences(
                    of: #"\.io(?=\d)"#,
                    with: ".io/",
                    options: .regularExpression
                )
            }
        }

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func sanitizeValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sanitizeGitCommit(_ raw: String?) -> String? {
        guard let value = sanitizeValue(raw) else { return nil }
        if value == "unknown" || value == "UNKNOWN" || value == "unset" || value == "UNSET" {
            return nil
        }
        return value
    }

    private static func readGitCommitFromRepository() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--short=12", "HEAD"]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)
            return sanitizeGitCommit(output)
        } catch {
            return nil
        }
    }

    private static func clampSampleRate(_ rate: Double) -> Double {
        min(max(rate, 0.0), 1.0)
    }

    private static func resolveProfilesSampleRate(infoPlist: InfoPlistReading) -> Double {
        if let value = infoPlist.double(forKey: infoPlistProfilesSampleRateKey) {
            return value
        }
        if let value = infoPlist.double(forKey: generatedInfoPlistProfilesSampleRateKey) {
            return value
        }
        if let value = infoPlist.double(forKey: legacyInfoPlistProfilesSampleRateKey) {
            return value
        }
        return 0.0
    }
}

// MARK: - Info.plist Reading Protocol

/// Protocol for reading Info.plist values, enabling dependency injection for tests.
nonisolated protocol InfoPlistReading: Sendable {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func double(forKey key: String) -> Double?
}

/// Default implementation that reads from a Bundle's Info.plist.
nonisolated struct InfoPlistReader: InfoPlistReading {
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
nonisolated struct MockInfoPlistReader: InfoPlistReading {
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
