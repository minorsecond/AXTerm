//
//  SentryManager.swift
//  AXTerm
//
//  Created by AXTerm on 2026-01-29.
//

import Foundation

#if canImport(Sentry)
import Sentry
#endif

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

/// Centralized, configurable Sentry integration.
///
/// - Important: This type is `@MainActor` because it is configured from UI settings and is used to tag UI-facing state.
@MainActor
final class SentryManager {
    static let shared = SentryManager()

    private var started = false
    private var config: SentryConfiguration?

    // Light sampling to avoid breadcrumb spam.
    private var decodeSuccessCounter: Int = 0

    private init() {}

    func startIfEnabled(settings: AppSettingsStore) {
        let config = SentryConfiguration.load(settings: settings)
        self.config = config

        guard config.enabledByUser, let dsn = config.dsn else {
            started = false
#if canImport(Sentry)
            SentrySDK.close()
#endif
            return
        }

        guard !started else {
            // Configuration may have changed (privacy toggles, etc.).
            configureScope(settings: settings)
            return
        }

#if canImport(Sentry)
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = config.environment
            options.releaseName = config.release
#if DEBUG
            options.debug = true
#endif
        }
#endif

        started = true
        configureScope(settings: settings)
        addBreadcrumb(category: "app.lifecycle", message: "Sentry started", level: .info, data: nil)
    }

    func configureScope(settings: AppSettingsStore) {
        self.config = SentryConfiguration.load(settings: settings)

#if canImport(Sentry)
        SentrySDK.configureScope { scope in
            scope.setTag(value: self.config?.environment ?? "unknown", key: "environment")
            scope.setTag(value: self.config?.release ?? "unknown", key: "release")
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

    func addBreadcrumb(
        category: String,
        message: String,
        level: SentryBreadcrumbLevel = .info,
        data: [String: Any]? = nil
    ) {
        guard started else { return }
#if canImport(Sentry)
        let sentryLevel: SentryLevel
        switch level {
        case .debug: sentryLevel = .debug
        case .info: sentryLevel = .info
        case .warning: sentryLevel = .warning
        case .error: sentryLevel = .error
        }
        let crumb = Breadcrumb()
        crumb.level = sentryLevel
        crumb.category = category
        crumb.message = message
        crumb.data = data
        SentrySDK.addBreadcrumb(crumb)
#endif
    }

    func capture(error: Error, message: String, level: SentryEventLevel = .error, extra: [String: Any]? = nil) {
        guard started else { return }
#if canImport(Sentry)
        let event = Event(level: mapEventLevel(level))
        event.message = SentryMessage(formatted: message)
        event.extra = extra
        SentrySDK.capture(event: event)
        SentrySDK.capture(error: error)
#endif
    }

    func captureMessage(_ message: String, level: SentryEventLevel = .warning, extra: [String: Any]? = nil) {
        guard started else { return }
#if canImport(Sentry)
        let event = Event(level: mapEventLevel(level))
        event.message = SentryMessage(formatted: message)
        event.extra = extra
        SentrySDK.capture(event: event)
#endif
    }

    // MARK: - Domain helpers

    func breadcrumbConnectAttempt(host: String, port: UInt16) {
        addBreadcrumb(
            category: "kiss.connection",
            message: "Connect attempt",
            level: .info,
            data: connectionData(host: host, port: port)
        )
    }

    func breadcrumbDisconnect() {
        addBreadcrumb(category: "kiss.connection", message: "Disconnect", level: .info, data: nil)
    }

    func captureConnectionFailure(_ message: String, error: Error? = nil) {
        if let error {
            capture(error: error, message: message, level: .error, extra: nil)
        } else {
            captureMessage(message, level: .error, extra: nil)
        }
    }

    func breadcrumbDecodeSuccessSampled(packet: Packet) {
        guard started else { return }
        decodeSuccessCounter += 1
        guard decodeSuccessCounter % 100 == 0 else { return }

        addBreadcrumb(
            category: "ax25.decode",
            message: "Decoded packet (sampled)",
            level: .info,
            data: packetData(packet, includeContents: false)
        )
    }

    func captureDecodeFailure(byteCount: Int) {
        captureMessage(
            "Failed to decode AX.25 frame",
            level: .warning,
            extra: ["byteCount": byteCount]
        )
    }

    func capturePersistenceFailure(_ operation: String, error: Error) {
        capture(error: error, message: "Persistence error: \(operation)", level: .error, extra: nil)
    }

    func capturePersistenceFailure(_ operation: String, errorDescription: String) {
        captureMessage(
            "Persistence error: \(operation)",
            level: .error,
            extra: ["error": errorDescription]
        )
    }

    func captureNotificationFailure(_ operation: String, error: Error? = nil) {
        if let error {
            capture(error: error, message: "Notification error: \(operation)", level: .error, extra: nil)
        } else {
            captureMessage("Notification error: \(operation)", level: .error, extra: nil)
        }
    }

    func breadcrumbWatchHit(packet: Packet, matchCount: Int) {
        addBreadcrumb(
            category: "watch.hit",
            message: "Watch hit",
            level: .info,
            data: packetData(packet, includeContents: false).merging(["matchCount": matchCount]) { current, _ in current }
        )
    }

    func breadcrumbInspectorRouteRequest(packetID: Packet.ID?) {
        addBreadcrumb(
            category: "ui.routing",
            message: "Inspector route request",
            level: .info,
            data: packetID.map { ["packetID": $0.uuidString] }
        )
    }

    // MARK: - Private helpers

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

#if canImport(Sentry)
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

