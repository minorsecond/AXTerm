//
//  SentryConfiguration.swift
//  AXTerm
//
//  Created by AXTerm on 2026-01-29.
//

import Foundation

struct SentryConfiguration: Equatable {
    /// `nil` means "not configured".
    var dsn: String?

    /// `debug` / `release` (per requirements).
    var environment: String

    /// Format: `AXTerm@<version>+<build>`
    var release: String

    /// If false, Sentry should not start even if DSN exists.
    var enabledByUser: Bool

    /// Privacy controls.
    var sendPacketContents: Bool
    var sendConnectionDetails: Bool

    static let infoPlistDSNKey = "SentryDSN"
    static let environmentVariableDSNKey = "SENTRY_DSN"

    static func load(
        bundle: Bundle = .main,
        environmentVariables: [String: String] = ProcessInfo.processInfo.environment,
        settings: AppSettingsStore
    ) -> SentryConfiguration {
        let dsn = Self.resolveDSN(
            environmentValue: environmentVariables[environmentVariableDSNKey],
            infoPlistValue: bundle.object(forInfoDictionaryKey: infoPlistDSNKey) as? String
        )

        return SentryConfiguration(
            dsn: dsn,
            environment: Self.buildEnvironment(),
            release: Self.buildRelease(bundle: bundle),
            enabledByUser: settings.sentryEnabled,
            sendPacketContents: settings.sentrySendPacketContents,
            sendConnectionDetails: settings.sentrySendConnectionDetails
        )
    }

    static func resolveDSN(environmentValue: String?, infoPlistValue: String?) -> String? {
        if let env = sanitizeDSNValue(environmentValue) {
            return env
        }
        return sanitizeDSNValue(infoPlistValue)
    }

    private static func buildEnvironment() -> String {
#if DEBUG
        return "debug"
#else
        return "release"
#endif
    }

    private static func buildRelease(bundle: Bundle) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "AXTerm"
        return "\(name)@\(version)+\(build)"
    }

    private static func sanitizeDSNValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // If build settings substitute an empty value, we treat it as "not configured".
        return trimmed.isEmpty ? nil : trimmed
    }
}

