//
//  WatchRules.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import Foundation

struct WatchMatch: Equatable {
    let matchedCallsigns: [String]
    let matchedKeywords: [String]

    var hasMatches: Bool {
        !matchedCallsigns.isEmpty || !matchedKeywords.isEmpty
    }
}

protocol WatchMatching {
    func match(packet: Packet) -> WatchMatch
}

@MainActor
final class WatchRuleMatcher: WatchMatching {
    private let settings: AppSettingsStore

    init(settings: AppSettingsStore) {
        self.settings = settings
    }

    func match(packet: Packet) -> WatchMatch {
        let callsignHits = matchCallsigns(packet: packet)
        let keywordHits = matchKeywords(packet: packet)
        return WatchMatch(matchedCallsigns: callsignHits, matchedKeywords: keywordHits)
    }

    private func matchCallsigns(packet: Packet) -> [String] {
        let watch = normalizedCallsigns(from: settings.watchCallsigns)
        guard !watch.isEmpty else { return [] }
        let tokens = packetCallsignTokens(packet: packet)
        return watch.filter { tokens.contains($0) }
    }

    private func matchKeywords(packet: Packet) -> [String] {
        let watch = normalizedKeywords(from: settings.watchKeywords)
        guard !watch.isEmpty else { return [] }
        let payload = (packet.infoText ?? packet.asciiPayload).lowercased()
        guard !payload.isEmpty else { return [] }
        return watch.filter { payload.contains($0.lowercased()) }
    }

    private func packetCallsignTokens(packet: Packet) -> Set<String> {
        var tokens = Set<String>()
        if let from = packet.from?.display {
            tokens.insert(from)
        }
        if let to = packet.to?.display {
            tokens.insert(to)
        }
        for address in packet.via {
            tokens.insert(address.display)
        }
        return tokens
    }

    private func normalizedCallsigns(from values: [String]) -> [String] {
        AppSettingsStore.sanitizeWatchList(values, normalize: CallsignValidator.normalize)
    }

    private func normalizedKeywords(from values: [String]) -> [String] {
        AppSettingsStore.sanitizeWatchList(values) { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

protocol WatchEventRecording {
    func recordWatchHit(packet: Packet, match: WatchMatch)
}

@MainActor
final class EventLogWatchRecorder: WatchEventRecording {
    private let store: EventLogStore
    private let settings: AppSettingsStore

    init(store: EventLogStore, settings: AppSettingsStore) {
        self.store = store
        self.settings = settings
    }

    func recordWatchHit(packet: Packet, match: WatchMatch) {
        let metadata = [
            "packetID": packet.id.uuidString,
            "from": packet.fromDisplay,
            "to": packet.toDisplay,
            "callsigns": match.matchedCallsigns.joined(separator: ","),
            "keywords": match.matchedKeywords.joined(separator: ",")
        ]

        let entry = AppEventRecord(
            id: UUID(),
            createdAt: Date(),
            level: .info,
            category: .watch,
            message: "Watch hit: \(packet.fromDisplay) → \(packet.toDisplay)",
            metadataJSON: DeterministicJSON.encodeDictionary(metadata)
        )

        let retentionLimit = settings.eventRetentionLimit
        DispatchQueue.global(qos: .utility).async { [store, retentionLimit] in
            do {
                try store.append(entry)
                try store.pruneIfNeeded(retentionLimit: retentionLimit)
            } catch {
                return
            }
        }
    }
}

protocol NotificationScheduling {
    func scheduleWatchNotification(packet: Packet, match: WatchMatch)
}
