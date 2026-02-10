//
//  WireLogStore.swift
//  AXTerm
//
//  Ring buffer for wire-level diagnostics.
//

import Combine
import Foundation

@MainActor
final class WireLogStore: ObservableObject {
    static let shared = WireLogStore()

    @Published private(set) var events: [WireLogEvent] = []
    var isEnabled = false
    var maxEvents = 2000

    private init() {}

    func append(direction: TxLogDirection, category: TxLogCategory, level: TxLog.LogLevel, message: String, data: [String: Any]?) {
        guard isEnabled else { return }

        let event = WireLogEvent(
            timestamp: Date(),
            direction: direction,
            category: category,
            level: level,
            message: message,
            data: data ?? [:]
        )

        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }
}

nonisolated struct WireLogEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let direction: TxLogDirection
    let category: TxLogCategory
    let level: TxLog.LogLevel
    let message: String
    let data: [String: Any]
}
