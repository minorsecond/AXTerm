//
//  SentryManager.swift
//  AXTerm
//
//  Created by AXTerm on 2026-01-29.
//

import Foundation
import OSLog

#if canImport(Sentry)
import Sentry
#endif

// MARK: - Level Enums

enum SentryBreadcrumbLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

enum SentryEventLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
    case fatal
}

// MARK: - SentryManager

/// Centralized Sentry integration with proper SDK configuration.
///
/// Features:
/// - Build-time configuration via xcconfig/Info.plist
/// - Safe initialization (no crashes if misconfigured)
/// - Privacy-aware (beforeSend redaction)
/// - Performance tracing support
/// - Debug-only logging
///
/// - Important: This type is `@MainActor` because it reads UI settings.
@MainActor
final class SentryManager {
    static let shared = SentryManager()

    private var started = false
    private var config: SentryConfiguration?
    private static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Light sampling to avoid breadcrumb spam for decode successes.
    private var decodeSuccessCounter: Int = 0

    /// Session tracking interval (default: 30 seconds).
    private static let sessionTrackingIntervalMillis: UInt = 30_000

    /// Keys to redact from events (case-insensitive partial match).
    private static let sensitiveKeys: Set<String> = [
        "password", "secret", "token", "apikey", "api_key",
        "authorization", "auth", "credential", "private"
    ]

    private let logger = Logger(subsystem: "AXTerm", category: "Sentry")

    private init() {}

    // MARK: - Initialization

    /// Start Sentry if configured and enabled.
    ///
    /// Safe to call multiple times; will only initialize once.
    /// Subsequent calls update the scope with new settings.
    func startIfEnabled(settings: AppSettingsStore) {
        if Self.isRunningUnitTests {
            logDebug("Sentry not started (unit tests)")
            return
        }
        let config = SentryConfiguration.load(settings: settings)
        self.config = config
        
    #if DEBUG
    logger.debug("Sentry startIfEnabled: enabledByUser=\(config.enabledByUser), dsnPresent=\(config.dsn != nil), shouldStart=\(config.shouldStart), env=\(config.environment)")
    if let dsn = config.dsn {
        logger.debug("Sentry DSN prefix: \(String(dsn.prefix(20)))…")
    }
    #endif

        guard config.shouldStart, let dsn = config.dsn else {
            if started {
                // User disabled Sentry after it was running.
                #if canImport(Sentry)
                SentrySDK.close()
                #endif
                started = false
                logDebug("Sentry closed (user disabled or DSN missing)")
            } else {
                logDebug("Sentry not started (disabled or DSN missing)")
            }
            return
        }

        guard !started else {
            // Already started; just update scope with new settings.
            configureScope(with: config)
            logDebug("Sentry scope updated")
            return
        }

        #if canImport(Sentry)
        SentrySDK.start { [weak self] options in
            self?.configureOptions(options, config: config, dsn: dsn)
        }
        #endif

        started = true
        configureScope(with: config)
        addBreadcrumb(category: "app.lifecycle", message: "Sentry initialized", level: .info, data: [
            "environment": config.environment,
            "release": config.release
        ])
        logDebug("Sentry started: environment=\(config.environment), release=\(config.release)")
    }

    #if canImport(Sentry)
    private func configureOptions(_ options: Options, config: SentryConfiguration, dsn: String) {
        // Core configuration
        options.dsn = dsn
        options.environment = config.environment
        options.releaseName = config.release
        options.dist = config.dist
        options.debug = config.debug

        // Tracing - enable performance monitoring
        options.tracesSampleRate = NSNumber(value: config.tracesSampleRate)

        // Session tracking
        options.enableAutoSessionTracking = true
        options.sessionTrackingIntervalMillis = Self.sessionTrackingIntervalMillis

        // Stack traces for all events
        options.attachStacktrace = true

        // Privacy: DO NOT send PII by default.
        options.sendDefaultPii = false

        // Crash handling
        options.enableCrashHandler = true

        // BeforeSend hook for redaction
        options.beforeSend = { [weak self] event in
            self?.redactSensitiveData(from: event)
        }
    }
    #endif

    // MARK: - Scope Configuration

    private func configureScope(with config: SentryConfiguration) {
        #if canImport(Sentry)
        SentrySDK.configureScope { scope in
            scope.setTag(value: config.environment, key: "environment")
            scope.setTag(value: config.release, key: "release")
            scope.setTag(value: config.dist, key: "dist")
        }
        #endif
    }

    func setConnectionTags(host: String?, port: UInt16?) {
        guard let config, config.sendConnectionDetails else { return }

        let hostValue = host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostTag = (hostValue?.isEmpty == false) ? hostValue : nil
        let portTag = port.map(String.init)

        #if canImport(Sentry)
        SentrySDK.configureScope { scope in
            if let hostTag {
                scope.setTag(value: hostTag, key: "kiss_host")
            }
            if let portTag {
                scope.setTag(value: portTag, key: "kiss_port")
            }
        }
        #endif
    }

    // MARK: - Redaction

    #if canImport(Sentry)
    private func redactSensitiveData(from event: Event) -> Event? {
        // Redact sensitive keys from extra data
        if var extra = event.extra {
            for key in extra.keys {
                if Self.sensitiveKeys.contains(where: { key.lowercased().contains($0) }) {
                    extra[key] = "[REDACTED]"
                }
            }
            event.extra = extra
        }

        // Redact from breadcrumb data
        event.breadcrumbs = event.breadcrumbs?.map { crumb in
            guard var data = crumb.data else { return crumb }
            for key in data.keys {
                if Self.sensitiveKeys.contains(where: { key.lowercased().contains($0) }) {
                    data[key] = "[REDACTED]"
                }
            }
            crumb.data = data
            return crumb
        }

        // Redact from tags
        if var tags = event.tags {
            for key in tags.keys {
                if Self.sensitiveKeys.contains(where: { key.lowercased().contains($0) }) {
                    tags[key] = "[REDACTED]"
                }
            }
            event.tags = tags
        }

        return event
    }
    #endif

    // MARK: - Breadcrumbs

    func addBreadcrumb(
        category: String,
        message: String,
        level: SentryBreadcrumbLevel = .info,
        data: [String: Any]? = nil
    ) {
        guard started else { return }
        #if canImport(Sentry)
        let crumb = Breadcrumb()
        crumb.level = mapBreadcrumbLevel(level)
        crumb.category = category
        crumb.message = message
        crumb.data = data
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    // MARK: - Error Capture

    func capture(error: Error, context: String, level: SentryEventLevel = .error, extra: [String: Any]? = nil) {
        guard started else { return }
        #if canImport(Sentry)
        SentrySDK.capture(error: error) { scope in
            scope.setLevel(self.mapEventLevel(level))
            scope.setContext(value: ["context": context], key: "error_context")
            if let extra {
                for (key, value) in extra {
                    scope.setExtra(value: value, key: key)
                }
            }
        }
        #endif
    }

    func captureMessage(_ message: String, level: SentryEventLevel = .warning, extra: [String: Any]? = nil) {
        guard started else { return }
        #if canImport(Sentry)
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(self.mapEventLevel(level))
            if let extra {
                for (key, value) in extra {
                    scope.setExtra(value: value, key: key)
                }
            }
        }
        #endif
    }

    // MARK: - Performance Tracing

    /// Start a performance transaction for a key operation.
    func startTransaction(name: String, operation: String) -> Any? {
        guard started else { return nil }
        #if canImport(Sentry)
        return SentrySDK.startTransaction(name: name, operation: operation)
        #else
        return nil
        #endif
    }

    /// Finish a performance transaction.
    func finishTransaction(_ transaction: Any?, status _: String = "ok") {
        #if canImport(Sentry)
        guard let span = transaction as? Span else { return }
        span.finish()
        #endif
    }

    // MARK: - Domain Helpers

    func breadcrumbConnectAttempt(host: String, port: UInt16) {
        addBreadcrumb(
            category: "kiss.connection",
            message: "Connect attempt",
            level: .info,
            data: connectionData(host: host, port: port)
        )
    }

    func breadcrumbConnected(host: String, port: UInt16) {
        addBreadcrumb(
            category: "kiss.connection",
            message: "Connected",
            level: .info,
            data: connectionData(host: host, port: port)
        )
    }

    func breadcrumbDisconnect() {
        addBreadcrumb(category: "kiss.connection", message: "Disconnect", level: .info, data: nil)
    }

    func captureConnectionFailure(_ message: String, error: Error? = nil) {
        if let error {
            capture(error: error, context: message, level: .error, extra: nil)
        } else {
            captureMessage(message, level: .error, extra: nil)
        }
    }

    func breadcrumbDecodeSuccessSampled(packet: Packet) {
        guard started else { return }
        decodeSuccessCounter += 1
        // Only log every 100th packet to avoid breadcrumb spam.
        guard decodeSuccessCounter % 100 == 0 else { return }

        addBreadcrumb(
            category: "ax25.decode",
            message: "Decoded packet (sampled, count=\(decodeSuccessCounter))",
            level: .info,
            data: packetData(packet, includeContents: false)
        )
    }

    func captureDecodeFailure(byteCount: Int, reason: String? = nil) {
        var extra: [String: Any] = ["byteCount": byteCount]
        if let reason {
            extra["reason"] = reason
        }
        captureMessage("Failed to decode AX.25 frame", level: .warning, extra: extra)
    }

    // MARK: - Database Helpers

    func breadcrumbDatabaseOpen(success: Bool, path: String? = nil) {
        addBreadcrumb(
            category: "db.lifecycle",
            message: success ? "Database opened" : "Database open failed",
            level: success ? .info : .error,
            data: path.map { ["path": $0] }
        )
    }

    func breadcrumbDatabaseMigration(version: Int, success: Bool) {
        addBreadcrumb(
            category: "db.migration",
            message: success ? "Migration to v\(version) succeeded" : "Migration to v\(version) failed",
            level: success ? .info : .error,
            data: ["version": version]
        )
    }

    func breadcrumbDatabasePrune(table: String, deletedCount: Int) {
        addBreadcrumb(
            category: "db.prune",
            message: "Pruned \(deletedCount) rows from \(table)",
            level: .info,
            data: ["table": table, "deletedCount": deletedCount]
        )
    }

    func breadcrumbDatabaseInsertBatch(table: String, count: Int) {
        addBreadcrumb(
            category: "db.insert",
            message: "Inserted \(count) rows into \(table)",
            level: .debug,
            data: ["table": table, "count": count]
        )
    }

    func capturePersistenceFailure(_ operation: String, error: Error) {
        capture(error: error, context: "Persistence error: \(operation)", level: .error, extra: nil)
    }

    func capturePersistenceFailure(_ operation: String, errorDescription: String) {
        captureMessage(
            "Persistence error: \(operation)",
            level: .error,
            extra: ["error": errorDescription]
        )
    }

    // MARK: - Notification Helpers

    func breadcrumbNotificationScheduled(packetID: UUID) {
        addBreadcrumb(
            category: "notification.schedule",
            message: "Watch notification scheduled",
            level: .info,
            data: ["packetID": packetID.uuidString]
        )
    }

    func captureNotificationFailure(_ operation: String, error: Error? = nil) {
        if let error {
            capture(error: error, context: "Notification error: \(operation)", level: .error, extra: nil)
        } else {
            captureMessage("Notification error: \(operation)", level: .error, extra: nil)
        }
    }

    // MARK: - Watch Helpers

    func breadcrumbWatchHit(packet: Packet, matchCount: Int) {
        addBreadcrumb(
            category: "watch.hit",
            message: "Watch hit",
            level: .info,
            data: packetData(packet, includeContents: false).merging(["matchCount": matchCount]) { current, _ in current }
        )
    }

    // MARK: - UI Helpers

    func breadcrumbInspectorRouteRequest(packetID: Packet.ID?) {
        addBreadcrumb(
            category: "ui.routing",
            message: "Inspector route request",
            level: .info,
            data: packetID.map { ["packetID": $0.uuidString] }
        )
    }

    // MARK: - Debug Helpers

    /// Send a test event to Sentry (debug builds only).
    func sendTestEvent() {
        #if DEBUG
        guard started else {
            logDebug("Cannot send test event: Sentry not started")
            return
        }
        captureMessage("AXTerm test event", level: .info, extra: [
            "test": true,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ])
        logDebug("Test event sent to Sentry")
        #endif
    }

    /// Check if Sentry is currently running.
    var isRunning: Bool {
        started
    }

    /// Current configuration (for diagnostics).
    var currentConfig: SentryConfiguration? {
        config
    }

    // MARK: - Private Helpers

    private func packetData(_ packet: Packet, includeContents: Bool) -> [String: Any] {
        let sendPacketContents = includeContents && (config?.sendPacketContents == true)
        return PacketSentryPayload
            .make(packet: packet, sendPacketContents: sendPacketContents)
            .toDictionary()
    }

    private func connectionData(host: String, port: UInt16) -> [String: Any]? {
        guard let config, config.sendConnectionDetails else { return nil }
        return ["kiss_host": host, "kiss_port": port]
    }

    private func logDebug(_ message: String) {
        #if DEBUG
        logger.debug("\(message)")
        #endif
    }

    #if canImport(Sentry)
    private func mapBreadcrumbLevel(_ level: SentryBreadcrumbLevel) -> SentryLevel {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }

    private func mapEventLevel(_ level: SentryEventLevel) -> SentryLevel {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        case .fatal: return .fatal
        }
    }
    #endif
}
