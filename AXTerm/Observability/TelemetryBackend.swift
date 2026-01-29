//
//  TelemetryBackend.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-14.
//

import Foundation

enum TelemetryLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
    case fatal
}

enum TelemetrySpanStatus: Sendable {
    case ok
    case error
}

protocol TelemetryBackend {
    var isEnabled: Bool { get }

    func addBreadcrumb(category: String, message: String, data: [String: Any]?, level: TelemetryLevel)
    func startSpan(name: String, operation: String?, data: [String: Any]?) -> Any?
    func finishSpan(_ span: Any?, status: TelemetrySpanStatus)
    func capture(error: Error, message: String, data: [String: Any]?)
    func capture(message: String, data: [String: Any]?)
}

struct NoOpTelemetryBackend: TelemetryBackend {
    var isEnabled: Bool { false }

    func addBreadcrumb(category _: String, message _: String, data _: [String: Any]?, level _: TelemetryLevel) {}
    func startSpan(name _: String, operation _: String?, data _: [String: Any]?) -> Any? { nil }
    func finishSpan(_ span _: Any?, status _: TelemetrySpanStatus) {}
    func capture(error _: Error, message _: String, data _: [String: Any]?) {}
    func capture(message _: String, data _: [String: Any]?) {}
}

struct TelemetryBackendFactory {
    static func makeDefault() -> TelemetryBackend {
        #if canImport(Sentry)
        return SentryTelemetryBackend()
        #else
        return NoOpTelemetryBackend()
        #endif
    }
}

#if canImport(Sentry)
import Sentry

final class SentryTelemetryBackend: TelemetryBackend {
    var isEnabled: Bool {
        SentrySDK.isEnabled
    }

    func addBreadcrumb(category: String, message: String, data: [String: Any]?, level: TelemetryLevel) {
        guard SentrySDK.isEnabled else { return }
        let crumb = Breadcrumb()
        crumb.level = mapLevel(level)
        crumb.category = category
        crumb.message = message
        crumb.data = data
        SentrySDK.addBreadcrumb(crumb)
    }

    func startSpan(name: String, operation: String?, data: [String: Any]?) -> Any? {
        guard SentrySDK.isEnabled else { return nil }
        let span = SentrySDK.startTransaction(name: name, operation: operation ?? "measure")
        if let data {
            for (key, value) in data {
                span.setData(value: value, key: key)
            }
        }
        return span
    }

    func finishSpan(_ span: Any?, status _: TelemetrySpanStatus) {
        guard SentrySDK.isEnabled else { return }
        guard let span = span as? Span else { return }
        span.finish()
    }

    func capture(error: Error, message: String, data: [String: Any]?) {
        guard SentrySDK.isEnabled else { return }
        SentrySDK.capture(error: error) { scope in
            scope.setContext(value: ["message": message], key: "error_context")
            if let data {
                for (key, value) in data {
                    scope.setExtra(value: value, key: key)
                }
            }
        }
    }

    func capture(message: String, data: [String: Any]?) {
        guard SentrySDK.isEnabled else { return }
        SentrySDK.capture(message: message) { scope in
            if let data {
                for (key, value) in data {
                    scope.setExtra(value: value, key: key)
                }
            }
        }
    }

    private func mapLevel(_ level: TelemetryLevel) -> SentryLevel {
        switch level {
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .warning
        case .error:
            return .error
        case .fatal:
            return .fatal
        }
    }
}
#endif
