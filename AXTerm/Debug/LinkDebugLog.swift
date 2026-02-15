//
//  LinkDebugLog.swift
//  AXTerm
//
//  In-memory debug store for link-level diagnostics.
//  Provides ring-buffered frame logs, stats, state timeline,
//  config entries, and parse errors for the Link Debug settings tab.
//

import Combine
import Foundation

// MARK: - Data Models

enum LinkDebugDirection: String, Sendable {
    case tx = "TX"
    case rx = "RX"
}

struct LinkDebugFrameEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let direction: LinkDebugDirection
    let rawBytes: Data
    let frameType: String
    let byteCount: Int
}

struct LinkDebugConfigEntry: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let rawBytes: Data
    let timestamp: Date
}

struct LinkDebugStateEntry: Identifiable, Sendable {
    let id = UUID()
    let fromState: String
    let toState: String
    let endpoint: String
    let timestamp: Date
}

struct LinkDebugErrorEntry: Identifiable, Sendable {
    let id = UUID()
    let message: String
    let rawBytes: Data?
    let timestamp: Date
}

// MARK: - LinkDebugLog

@MainActor
final class LinkDebugLog: ObservableObject {
    static let shared = LinkDebugLog()

    // MARK: - Stats

    @Published private(set) var totalBytesIn: Int = 0
    @Published private(set) var totalBytesOut: Int = 0
    @Published private(set) var ax25FrameCount: Int = 0
    @Published private(set) var telemetryFrameCount: Int = 0
    @Published private(set) var unknownFrameCount: Int = 0
    @Published private(set) var parseErrorCount: Int = 0

    // MARK: - Ring Buffers

    static let maxFrames = 500
    static let maxStateEntries = 100
    static let maxErrorEntries = 100

    @Published private(set) var frames: [LinkDebugFrameEntry] = []
    @Published private(set) var configEntries: [LinkDebugConfigEntry] = []
    @Published private(set) var stateTimeline: [LinkDebugStateEntry] = []
    @Published private(set) var parseErrors: [LinkDebugErrorEntry] = []

    // MARK: - Recording

    func recordRxBytes(_ count: Int) {
        totalBytesIn += count
    }

    func recordTxBytes(_ count: Int) {
        totalBytesOut += count
    }

    func recordFrame(_ entry: LinkDebugFrameEntry) {
        frames.append(entry)
        if frames.count > Self.maxFrames {
            frames.removeFirst(frames.count - Self.maxFrames)
        }

        switch entry.frameType.lowercased() {
        case "ax25":
            ax25FrameCount += 1
        case "telemetry":
            telemetryFrameCount += 1
        default:
            unknownFrameCount += 1
        }
    }

    func recordStateChange(from: String, to: String, endpoint: String) {
        let entry = LinkDebugStateEntry(
            fromState: from,
            toState: to,
            endpoint: endpoint,
            timestamp: Date()
        )
        stateTimeline.append(entry)
        if stateTimeline.count > Self.maxStateEntries {
            stateTimeline.removeFirst(stateTimeline.count - Self.maxStateEntries)
        }
    }

    func recordParseError(message: String, rawBytes: Data? = nil) {
        let entry = LinkDebugErrorEntry(
            message: message,
            rawBytes: rawBytes,
            timestamp: Date()
        )
        parseErrors.append(entry)
        parseErrorCount += 1
        if parseErrors.count > Self.maxErrorEntries {
            parseErrors.removeFirst(parseErrors.count - Self.maxErrorEntries)
        }
    }

    func recordKISSInit(label: String, rawBytes: Data) {
        let entry = LinkDebugConfigEntry(
            label: label,
            rawBytes: rawBytes,
            timestamp: Date()
        )
        configEntries.append(entry)
    }

    func clear() {
        totalBytesIn = 0
        totalBytesOut = 0
        ax25FrameCount = 0
        telemetryFrameCount = 0
        unknownFrameCount = 0
        parseErrorCount = 0
        frames.removeAll()
        configEntries.removeAll()
        stateTimeline.removeAll()
        parseErrors.removeAll()
    }
}
