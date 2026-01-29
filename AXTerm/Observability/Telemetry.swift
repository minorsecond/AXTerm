//
//  Telemetry.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-14.
//

import Foundation

enum Telemetry {
    static var isEnabled: Bool {
        backend.isEnabled
    }

    static func breadcrumb(
        category: String,
        message: String,
        data: [String: Any]? = nil,
        level: TelemetryLevel = .info
    ) {
        backend.addBreadcrumb(category: category, message: message, data: data, level: level)
    }

    @discardableResult
    static func measure<T>(
        name: String,
        operation: String? = nil,
        data: [String: Any]? = nil,
        _ block: () throws -> T
    ) rethrows -> T {
        let span = backend.startSpan(name: name, operation: operation, data: data)
        do {
            let result = try block()
            backend.finishSpan(span, status: .ok)
            return result
        } catch {
            backend.finishSpan(span, status: .error)
            throw error
        }
    }

    static func capture(error: Error, message: String, data: [String: Any]? = nil) {
        backend.capture(error: error, message: message, data: data)
    }

    static func capture(message: String, data: [String: Any]? = nil) {
        backend.capture(message: message, data: data)
    }

    static func setBackend(_ backend: TelemetryBackend) {
        self.backend = backend
    }

    static var backendForTesting: TelemetryBackend {
        backend
    }

    private static var backend: TelemetryBackend = TelemetryBackendFactory.makeDefault()
}

enum TelemetryContext {
    static let packetCount = "packetCount"
    static let uniqueStations = "uniqueStations"
    static let activeBucket = "activeBucket"
    static let payloadSize = "payloadSize"
}
