//
//  TelemetryBackend.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-14.
//

import Foundation

nonisolated enum TelemetryLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
    case fatal
}

nonisolated enum TelemetrySpanStatus: Sendable {
    case ok
    case error
}

typealias TelemetrySpanToken = AnyObject

nonisolated protocol TelemetryBackend {
    var isEnabled: Bool { get }

    func addBreadcrumb(category: String, message: String, data: [String: Any]?, level: TelemetryLevel)
    func startSpan(name: String, operation: String?, data: [String: Any]?) -> TelemetrySpanToken?
    func updateSpan(_ span: TelemetrySpanToken?, data: [String: Any])
    func finishSpan(_ span: TelemetrySpanToken?, status: TelemetrySpanStatus)
    func capture(error: Error, message: String, data: [String: Any]?)
    func capture(message: String, data: [String: Any]?)
}

nonisolated struct NoOpTelemetryBackend: TelemetryBackend {
    var isEnabled: Bool { false }

    func addBreadcrumb(category: String, message: String, data: [String: Any]?, level: TelemetryLevel) {}
    func startSpan(name: String, operation: String?, data: [String: Any]?) -> TelemetrySpanToken? { nil }
    func updateSpan(_ span: TelemetrySpanToken?, data: [String: Any]) {}
    func finishSpan(_ span: TelemetrySpanToken?, status: TelemetrySpanStatus) {}
    func capture(error: Error, message: String, data: [String: Any]?) {}
    func capture(message: String, data: [String: Any]?) {}
}

nonisolated struct TelemetryBackendFactory {
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

nonisolated final class SentryTelemetryBackend: TelemetryBackend {
    var isEnabled: Bool {
        SentrySDK.isEnabled
    }

    func addBreadcrumb(category: String, message: String, data: [String: Any]?, level: TelemetryLevel) {
        guard SentrySDK.isEnabled else { return }
        // Same flood control and content-privacy gating as SentryManager —
        // this path used to bypass both.
        switch SharedBreadcrumbBudget.shared.admit(category: category, level: budgetLevel(level)) {
        case .drop:
            return
        case .allowAfterSuppressing(let suppressed):
            let summary = Breadcrumb()
            summary.level = .warning
            summary.category = category
            summary.message = "…\(suppressed) \(category) breadcrumb(s) suppressed by flood control"
            SentrySDK.addBreadcrumb(summary)
        case .allow:
            break
        }
        let crumb = Breadcrumb()
        crumb.level = mapLevel(level)
        crumb.category = category
        crumb.message = message
        crumb.data = TelemetryContentRedactor.redact(
            data,
            allowContents: TelemetryPrivacy.shared.allowPacketContents
        )
        SentrySDK.addBreadcrumb(crumb)
    }

    private func budgetLevel(_ level: TelemetryLevel) -> SentryBreadcrumbLevel {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error, .fatal: return .error
        }
    }

    func startSpan(name: String, operation: String?, data: [String: Any]?) -> TelemetrySpanToken? {
        guard SentrySDK.isEnabled else { return nil }
        let span = SentrySDK.startTransaction(name: name, operation: operation ?? "measure")
        if let data {
            for (key, value) in data {
                span.setData(value: value, key: key)
            }
        }
        return span
    }

    func updateSpan(_ span: TelemetrySpanToken?, data: [String: Any]) {
        guard SentrySDK.isEnabled else { return }
        guard let span = span as? Span else { return }
        for (key, value) in data {
            span.setData(value: value, key: key)
        }
    }

    func finishSpan(_ span: TelemetrySpanToken?, status _: TelemetrySpanStatus) {
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
