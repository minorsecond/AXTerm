//
//  TransmissionLogger.swift
//  AXTerm
//
//  Comprehensive logging for transmission subsystem.
//  Provides visually formatted debug output and Sentry integration.
//
//  Usage:
//    TxLog.outbound(.frame, "Sending UI frame", ["dest": "N0CALL", "size": 128])
//    TxLog.inbound(.axdp, "AXDP PING received", ["peer": "K0ABC"])
//    TxLog.error(.kiss, "Connection failed", error: someError)
//

import Foundation
import OSLog

// MARK: - Log Category

/// Categories for transmission logging
enum TxLogCategory: String {
    case kiss = "KISS"
    case ax25 = "AX25"
    case fx25 = "FX25"
    case axdp = "AXDP"
    case frame = "FRAME"
    case queue = "QUEUE"
    case session = "SESSION"
    case transport = "TRANSPORT"
    case compression = "COMPRESS"
    case capability = "CAPABILITY"
    case rtt = "RTT"
    case congestion = "CONGESTION"
    case path = "PATH"
    case settings = "SETTINGS"

    var emoji: String {
        switch self {
        case .kiss: return "🔌"
        case .ax25: return "📡"
        case .fx25: return "🛡️"
        case .axdp: return "📦"
        case .frame: return "📋"
        case .queue: return "📥"
        case .session: return "🔗"
        case .transport: return "🚀"
        case .compression: return "🗜️"
        case .capability: return "🤝"
        case .rtt: return "⏱️"
        case .congestion: return "🚦"
        case .path: return "🛤️"
        case .settings: return "⚙️"
        }
    }
}

// MARK: - Log Direction

/// Direction indicator for message flow
enum TxLogDirection: String {
    case outbound = "TX"
    case inbound = "RX"
    case internal_ = "──"

    var arrow: String {
        switch self {
        case .outbound: return "→"
        case .inbound: return "←"
        case .internal_: return "•"
        }
    }

    var color: String {
        switch self {
        case .outbound: return "🔵"
        case .inbound: return "🟢"
        case .internal_: return "⚪"
        }
    }
}

// MARK: - Transmission Logger

/// Centralized logging for all transmission-related operations.
///
/// Features:
/// - Visually formatted console output (DEBUG builds)
/// - OSLog integration for system logging
/// - Sentry breadcrumbs and error capture (all builds)
/// - Structured metadata for easy parsing
///
/// Usage:
/// ```swift
/// TxLog.outbound(.ax25, "Sending I-frame", ["seq": 3, "dest": "N0CALL"])
/// TxLog.inbound(.axdp, "PING received", ["peer": "K0ABC-5"])
/// TxLog.error(.kiss, "Send failed", error: transportError)
/// ```
@MainActor
final class TxLog {
    static let shared = TxLog()

    private let logger = Logger(subsystem: "AXTerm", category: "Transmission")
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    /// Enable/disable verbose console output (DEBUG builds only)
    var verboseConsole = false
    /// Capture wire events for advanced diagnostics UI (DEBUG builds only)
    var captureWireEvents = false

    private init() {}

    static func configure(wireDebugEnabled: Bool) {
        Task { @MainActor in
            shared.verboseConsole = wireDebugEnabled
            shared.captureWireEvents = wireDebugEnabled
            WireLogStore.shared.isEnabled = wireDebugEnabled
        }
    }

    // MARK: - Public API

    /// Log an outbound (TX) message
    static func outbound(_ category: TxLogCategory, _ message: String, _ data: [String: Any]? = nil) {
        Task { @MainActor in
            shared.log(direction: .outbound, category: category, message: message, data: data, level: .info)
        }
    }

    /// Log an inbound (RX) message
    static func inbound(_ category: TxLogCategory, _ message: String, _ data: [String: Any]? = nil) {
        Task { @MainActor in
            shared.log(direction: .inbound, category: category, message: message, data: data, level: .info)
        }
    }

    /// Log an internal operation
    static func debug(_ category: TxLogCategory, _ message: String, _ data: [String: Any]? = nil) {
        Task { @MainActor in
            shared.log(direction: .internal_, category: category, message: message, data: data, level: .debug)
        }
    }

    /// Log a warning
    static func warning(_ category: TxLogCategory, _ message: String, _ data: [String: Any]? = nil) {
        Task { @MainActor in
            shared.log(direction: .internal_, category: category, message: message, data: data, level: .warning)
        }
    }

    /// Log an error (always captured by Sentry)
    static func error(_ category: TxLogCategory, _ message: String, error: Error? = nil, _ data: [String: Any]? = nil) {
        Task { @MainActor in
            shared.logError(category: category, message: message, error: error, data: data)
        }
    }

    /// Log frame hex dump (DEBUG only, truncated)
    static func hexDump(_ category: TxLogCategory, _ label: String, data: Data, maxBytes: Int = 64) {
        #if DEBUG
        Task { @MainActor in
            shared.logHexDump(category: category, label: label, data: data, maxBytes: maxBytes)
        }
        #endif
    }

    // MARK: - KISS-specific logging

    static func kissConnect(host: String, port: UInt16) {
        outbound(.kiss, "Connecting", ["host": host, "port": port])
        SentryManager.shared.addBreadcrumb(
            category: "tx.kiss",
            message: "KISS connect",
            level: .info,
            data: ["host": host, "port": port]
        )
    }

    static func kissConnected(host: String, port: UInt16) {
        inbound(.kiss, "Connected", ["host": host, "port": port])
        SentryManager.shared.addBreadcrumb(
            category: "tx.kiss",
            message: "KISS connected",
            level: .info,
            data: ["host": host, "port": port]
        )
    }

    static func kissDisconnected(reason: String? = nil) {
        debug(.kiss, "Disconnected", reason.map { ["reason": $0] })
        SentryManager.shared.addBreadcrumb(
            category: "tx.kiss",
            message: "KISS disconnected",
            level: .info,
            data: reason.map { ["reason": $0] }
        )
    }

    static func kissSend(frameId: UUID, size: Int) {
        outbound(.kiss, "Send frame", ["frameId": frameId.uuidString.prefix(8), "size": size])
    }

    static func kissSendComplete(frameId: UUID, success: Bool, error: Error? = nil) {
        if success {
            debug(.kiss, "Send complete", ["frameId": String(frameId.uuidString.prefix(8))])
        } else {
            TxLog.error(.kiss, "Send failed", error: error, ["frameId": String(frameId.uuidString.prefix(8))])
        }
    }

    static func kissReceive(size: Int) {
        inbound(.kiss, "Received", ["size": size])
    }

    // MARK: - AX.25-specific logging

    static func ax25Encode(dest: String, src: String, type: String, size: Int) {
        outbound(.ax25, "Encode \(type)", ["dest": dest, "src": src, "size": size])
    }

    static func ax25Decode(dest: String, src: String, type: String, size: Int) {
        inbound(.ax25, "Decode \(type)", ["dest": dest, "src": src, "size": size])
    }

    static func ax25DecodeError(reason: String, size: Int) {
        error(.ax25, "Decode failed: \(reason)", error: nil, ["size": size])
        SentryManager.shared.captureMessage(
            "AX.25 decode failed: \(reason)",
            level: .warning,
            extra: ["size": size]
        )
    }

    // MARK: - AXDP-specific logging

    static func axdpEncode(type: String, sessionId: UInt16, messageId: UInt32, payloadSize: Int) {
        outbound(.axdp, "Encode \(type)", [
            "session": sessionId,
            "msgId": messageId,
            "payload": payloadSize
        ])
    }

    static func axdpDecode(type: String, sessionId: UInt16, messageId: UInt32, payloadSize: Int) {
        inbound(.axdp, "Decode \(type)", [
            "session": sessionId,
            "msgId": messageId,
            "payload": payloadSize
        ])
    }

    static func axdpDecodeError(reason: String, data: Data) {
        error(.axdp, "Decode failed: \(reason)", error: nil, ["size": data.count])
        SentryManager.shared.captureMessage(
            "AXDP decode failed: \(reason)",
            level: .warning,
            extra: ["size": data.count]
        )
    }

    static func axdpPing(peer: String) {
        outbound(.axdp, "PING", ["peer": peer])
    }

    static func axdpPong(peer: String, rtt: Double?) {
        inbound(.axdp, "PONG", ["peer": peer, "rtt": rtt.map { String(format: "%.1fms", $0 * 1000) } ?? "n/a"])
    }

    static func axdpCapability(peer: String, caps: [String]) {
        inbound(.capability, "Capabilities", ["peer": peer, "caps": caps.joined(separator: ", ")])
    }

    // MARK: - Compression logging

    static func compressionEncode(algorithm: String, originalSize: Int, compressedSize: Int) {
        let ratio = originalSize > 0 ? Double(compressedSize) / Double(originalSize) : 1.0
        outbound(.compression, "Compress (\(algorithm))", [
            "original": originalSize,
            "compressed": compressedSize,
            "ratio": String(format: "%.1f%%", ratio * 100)
        ])
    }

    static func compressionDecode(algorithm: String, compressedSize: Int, decompressedSize: Int) {
        inbound(.compression, "Decompress (\(algorithm))", [
            "compressed": compressedSize,
            "decompressed": decompressedSize
        ])
    }

    static func compressionError(operation: String, reason: String) {
        error(.compression, "\(operation) failed: \(reason)")
        SentryManager.shared.captureMessage(
            "Compression \(operation) failed: \(reason)",
            level: .warning,
            extra: nil
        )
    }

    // MARK: - Queue logging

    static func queueEnqueue(frameId: UUID, dest: String, priority: String, queueDepth: Int) {
        debug(.queue, "Enqueue", [
            "frameId": String(frameId.uuidString.prefix(8)),
            "dest": dest,
            "priority": priority,
            "depth": queueDepth
        ])
    }

    static func queueDequeue(frameId: UUID, dest: String) {
        debug(.queue, "Dequeue", [
            "frameId": String(frameId.uuidString.prefix(8)),
            "dest": dest
        ])
    }

    static func queueCancel(frameId: UUID, reason: String) {
        debug(.queue, "Cancel", [
            "frameId": String(frameId.uuidString.prefix(8)),
            "reason": reason
        ])
    }

    // MARK: - Session logging

    static func sessionOpen(sessionId: UUID, peer: String, mode: String) {
        outbound(.session, "Open", [
            "session": String(sessionId.uuidString.prefix(8)),
            "peer": peer,
            "mode": mode
        ])
        SentryManager.shared.addBreadcrumb(
            category: "tx.session",
            message: "Session open",
            level: .info,
            data: ["peer": peer, "mode": mode]
        )
    }

    static func sessionClose(sessionId: UUID, peer: String, reason: String) {
        debug(.session, "Close", [
            "session": String(sessionId.uuidString.prefix(8)),
            "peer": peer,
            "reason": reason
        ])
        SentryManager.shared.addBreadcrumb(
            category: "tx.session",
            message: "Session close",
            level: .info,
            data: ["peer": peer, "reason": reason]
        )
    }

    static func sessionStateChange(sessionId: UUID, from: String, to: String) {
        debug(.session, "State: \(from) → \(to)", [
            "session": String(sessionId.uuidString.prefix(8))
        ])
    }

    // MARK: - RTT/Congestion logging

    static func rttUpdate(peer: String, srtt: Double, rttvar: Double, rto: Double) {
        debug(.rtt, "Update", [
            "peer": peer,
            "srtt": String(format: "%.1fms", srtt * 1000),
            "rttvar": String(format: "%.1fms", rttvar * 1000),
            "rto": String(format: "%.1fms", rto * 1000)
        ])
    }

    static func congestionWindowChange(peer: String, cwnd: Int, reason: String) {
        debug(.congestion, reason, [
            "peer": peer,
            "cwnd": cwnd
        ])
    }

    // MARK: - Path logging

    static func pathSuggestion(dest: String, path: String, score: Double, reason: String) {
        debug(.path, "Suggestion", [
            "dest": dest,
            "path": path.isEmpty ? "(direct)" : path,
            "score": String(format: "%.2f", score),
            "reason": reason
        ])
    }

    // MARK: - Internal Implementation

    enum LogLevel {
        case debug, info, warning, error
    }

    private func log(
        direction: TxLogDirection,
        category: TxLogCategory,
        message: String,
        data: [String: Any]?,
        level: LogLevel
    ) {
        let timestamp = dateFormatter.string(from: Date())
        let dataStr = formatData(data)

        // Console output (DEBUG only, visually formatted)
        #if DEBUG
        if verboseConsole {
            let line = "\(timestamp) \(direction.color) \(direction.rawValue) \(category.emoji) [\(category.rawValue)] \(message)\(dataStr)"
            print(line)
        }
        if captureWireEvents {
            WireLogStore.shared.append(
                direction: direction,
                category: category,
                level: level,
                message: message,
                data: data
            )
        }
        #endif

        // OSLog (all builds)
        let osLogMessage = "[\(direction.rawValue)] [\(category.rawValue)] \(message)\(dataStr)"
        switch level {
        case .debug:
            logger.debug("\(osLogMessage)")
        case .info:
            logger.info("\(osLogMessage)")
        case .warning:
            logger.warning("\(osLogMessage)")
        case .error:
            logger.error("\(osLogMessage)")
        }

        // Sentry breadcrumb (all builds, sampling for high-volume)
        let sentryCategory = "tx.\(category.rawValue.lowercased())"
        SentryManager.shared.addBreadcrumb(
            category: sentryCategory,
            message: "\(direction.rawValue): \(message)",
            level: mapToSentryLevel(level),
            data: data
        )
    }

    private func logError(category: TxLogCategory, message: String, error: Error?, data: [String: Any]?) {
        let timestamp = dateFormatter.string(from: Date())
        let dataStr = formatData(data)
        let errorStr = error.map { " | Error: \($0.localizedDescription)" } ?? ""

        // Console output
        #if DEBUG
        let line = "❌ \(timestamp) [\(category.rawValue)] \(message)\(dataStr)\(errorStr)"
        print(line)
        #endif

        // OSLog
        let osLogMessage = "[ERROR] [\(category.rawValue)] \(message)\(dataStr)\(errorStr)"
        logger.error("\(osLogMessage)")

        // Sentry capture (all builds)
        var extra = data ?? [:]
        extra["category"] = category.rawValue
        if let error = error {
            SentryManager.shared.capture(
                error: error,
                context: "TX[\(category.rawValue)]: \(message)",
                level: .error,
                extra: extra
            )
        } else {
            SentryManager.shared.captureMessage(
                "TX[\(category.rawValue)]: \(message)",
                level: .error,
                extra: extra
            )
        }
    }

    private func logHexDump(category: TxLogCategory, label: String, data: Data, maxBytes: Int) {
        let truncated = data.count > maxBytes
        let bytesToShow = min(data.count, maxBytes)
        let hex = data.prefix(bytesToShow).map { String(format: "%02X", $0) }.joined(separator: " ")
        let suffix = truncated ? "… (+\(data.count - maxBytes) more)" : ""

        #if DEBUG
        print("   \(category.emoji) [\(category.rawValue)] \(label) (\(data.count) bytes):")
        print("      \(hex)\(suffix)")
        #endif

        logger.debug("[\(category.rawValue)] \(label): \(hex)\(suffix)")
    }

    private func formatData(_ data: [String: Any]?) -> String {
        guard let data = data, !data.isEmpty else { return "" }
        let pairs = data.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        return " | \(pairs)"
    }

    private func mapToSentryLevel(_ level: LogLevel) -> SentryBreadcrumbLevel {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
}
