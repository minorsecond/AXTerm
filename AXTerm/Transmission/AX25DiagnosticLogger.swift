//
//  AX25DiagnosticLogger.swift
//  AXTerm
//
//  Comprehensive diagnostic logging system for debugging AX.25 and BLE issues.
//  Provides structured, filterable logging with hex dumps, timing, and context.
//

import Foundation
import OSLog

// MARK: - Diagnostic Log Level

/// Diagnostic log levels for fine-grained control
enum AX25DiagnosticLevel: Int, Comparable, CaseIterable {
    case verbose = 0  // Every byte, every event
    case debug = 1    // Detailed debugging info
    case info = 2     // Key events and state changes
    case warning = 3  // Potential issues
    case error = 4    // Actual errors
    
    var name: String {
        switch self {
        case .verbose: return "VERBOSE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        }
    }
    
    static func < (lhs: AX25DiagnosticLevel, rhs: AX25DiagnosticLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Diagnostic Logger Configuration

/// Configuration for diagnostic logging
struct AX25DiagnosticConfig: Sendable {
    /// Minimum log level to output
    var minimumLevel: AX25DiagnosticLevel = .info
    
    /// Enable hex dumps of packet data
    var enableHexDumps: Bool = true
    
    /// Maximum bytes to include in hex dumps (0 = unlimited)
    var maxHexDumpBytes: Int = 256
    
    /// Log KISS frame boundaries (FEND detection)
    var logKISSFraming: Bool = true
    
    /// Log BLE characteristic assignments and changes
    var logBLECharacteristics: Bool = true
    
    /// Log every packet reception with timestamp
    var logPacketTimestamps: Bool = true
    
    /// Log AX.25 frame parsing details
    var logAX25Parsing: Bool = true
    
    /// Track and log gaps in packet reception
    var detectReceptionGaps: Bool = true
    
    /// Gap threshold in seconds (log warning if no packets for this long)
    var receptionGapThreshold: TimeInterval = 5.0
    
    /// Enable performance timing measurements
    var enablePerformanceTiming: Bool = false
    
    /// Preset configurations
    static let minimal = AX25DiagnosticConfig(
        minimumLevel: .error,
        enableHexDumps: false,
        logKISSFraming: false,
        logBLECharacteristics: false,
        logPacketTimestamps: false,
        logAX25Parsing: false,
        detectReceptionGaps: false,
        enablePerformanceTiming: false
    )
    
    static let standard = AX25DiagnosticConfig(
        minimumLevel: .info,
        enableHexDumps: true,
        maxHexDumpBytes: 128,
        logKISSFraming: true,
        logBLECharacteristics: true,
        logPacketTimestamps: true,
        logAX25Parsing: true,
        detectReceptionGaps: true,
        receptionGapThreshold: 5.0,
        enablePerformanceTiming: false
    )
    
    static let comprehensive = AX25DiagnosticConfig(
        minimumLevel: .verbose,
        enableHexDumps: true,
        maxHexDumpBytes: 0,
        logKISSFraming: true,
        logBLECharacteristics: true,
        logPacketTimestamps: true,
        logAX25Parsing: true,
        detectReceptionGaps: true,
        receptionGapThreshold: 3.0,
        enablePerformanceTiming: true
    )
}

// MARK: - Diagnostic Logger

/// Comprehensive diagnostic logger for AX.25 and BLE debugging
actor AX25DiagnosticLogger {
    static let shared = AX25DiagnosticLogger()
    
    private let logger = Logger(subsystem: "com.rosswardrup.AXTerm", category: "AX25Diagnostics")
    private var config = AX25DiagnosticConfig.standard
    
    // Reception tracking
    private var lastReceptionTime: [String: Date] = [:]
    private var receptionCount: [String: Int] = [:]
    private var totalBytesReceived: [String: Int] = [:]
    
    // Performance tracking
    private var operationStartTimes: [String: Date] = [:]
    
    // Session tracking
    private var sessionStartTime = Date()
    private var sessionID = UUID().uuidString.prefix(8)
    
    private init() {}
    
    // MARK: - Configuration
    
    func updateConfig(_ newConfig: AX25DiagnosticConfig) {
        config = newConfig
        log(.info, category: "Config", message: "Diagnostic logging configuration updated")
    }
    
    func setMinimumLevel(_ level: AX25DiagnosticLevel) {
        config.minimumLevel = level
        log(.info, category: "Config", message: "Minimum log level set to \(level.name)")
    }
    
    // MARK: - Core Logging
    
    private func log(
        _ level: AX25DiagnosticLevel,
        category: String,
        message: String,
        endpoint: String? = nil,
        data: Data? = nil,
        metadata: [String: String] = [:]
    ) {
        guard level >= config.minimumLevel else { return }
        
        var logMessage = "[\(category)]"
        if let endpoint {
            logMessage += " [\(endpoint)]"
        }
        logMessage += " \(message)"
        
        // Add metadata
        if !metadata.isEmpty {
            let metaStr = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            logMessage += " {\(metaStr)}"
        }
        
        // Add hex dump if enabled and data present
        if let data, !data.isEmpty, config.enableHexDumps {
            let dumpData = config.maxHexDumpBytes > 0 ? data.prefix(config.maxHexDumpBytes) : data
            logMessage += "\n" + hexDump(dumpData)
            if config.maxHexDumpBytes > 0 && data.count > config.maxHexDumpBytes {
                logMessage += "\n... (\(data.count - config.maxHexDumpBytes) more bytes)"
            }
        }
        
        // Log to OSLog with appropriate level
        switch level {
        case .verbose:
            logger.debug("\(logMessage, privacy: .public)")
        case .debug:
            logger.debug("\(logMessage, privacy: .public)")
        case .info:
            logger.info("\(logMessage, privacy: .public)")
        case .warning:
            logger.warning("\(logMessage, privacy: .public)")
        case .error:
            logger.error("\(logMessage, privacy: .public)")
        }
    }
    
    // MARK: - BLE Diagnostics
    
    func logBLEServiceDiscovered(
        endpoint: String,
        serviceUUID: String,
        isKnownService: Bool
    ) {
        guard config.logBLECharacteristics else { return }
        log(
            .info,
            category: "BLE",
            message: "Service discovered: \(serviceUUID)",
            endpoint: endpoint,
            metadata: ["known": isKnownService ? "yes" : "no"]
        )
    }
    
    func logBLECharacteristicDiscovered(
        endpoint: String,
        serviceUUID: String,
        characteristicUUID: String,
        properties: String
    ) {
        guard config.logBLECharacteristics else { return }
        log(
            .debug,
            category: "BLE",
            message: "Characteristic discovered: \(characteristicUUID)",
            endpoint: endpoint,
            metadata: [
                "service": serviceUUID,
                "properties": properties
            ]
        )
    }
    
    func logBLECharacteristicSelected(
        endpoint: String,
        role: String,
        characteristicUUID: String,
        priority: Int,
        reason: String
    ) {
        guard config.logBLECharacteristics else { return }
        log(
            .info,
            category: "BLE",
            message: "\(role) characteristic selected: \(characteristicUUID)",
            endpoint: endpoint,
            metadata: [
                "priority": String(priority),
                "reason": reason
            ]
        )
    }
    
    func logBLECharacteristicOverride(
        endpoint: String,
        role: String,
        oldUUID: String,
        newUUID: String,
        reason: String
    ) {
        log(
            .warning,
            category: "BLE",
            message: "⚠️ \(role) CHARACTERISTIC OVERRIDE (BUG RISK!)",
            endpoint: endpoint,
            metadata: [
                "old": oldUUID,
                "new": newUUID,
                "reason": reason
            ]
        )
    }
    
    func logBLESubscriptionChange(
        endpoint: String,
        characteristicUUID: String,
        enabled: Bool,
        success: Bool,
        error: String? = nil
    ) {
        guard config.logBLECharacteristics else { return }
        let level: AX25DiagnosticLevel = success ? .info : .error
        var metadata: [String: String] = [
            "state": enabled ? "enabled" : "disabled",
            "result": success ? "success" : "failed"
        ]
        if let error {
            metadata["error"] = error
        }
        log(
            level,
            category: "BLE",
            message: "Subscription change for \(characteristicUUID)",
            endpoint: endpoint,
            metadata: metadata
        )
    }
    
    func logBLEDataFiltered(
        endpoint: String,
        characteristicUUID: String,
        expectedUUID: String,
        dataSize: Int
    ) {
        log(
            .error,
            category: "BLE",
            message: "🚫 DATA FILTERED - Wrong characteristic!",
            endpoint: endpoint,
            metadata: [
                "received_from": characteristicUUID,
                "expected": expectedUUID,
                "bytes_discarded": String(dataSize)
            ]
        )
    }
    
    // MARK: - KISS Diagnostics
    
    func logKISSFrameStart(endpoint: String, portByte: UInt8? = nil) {
        guard config.logKISSFraming else { return }
        var metadata: [String: String] = [:]
        if let portByte {
            let port = (portByte >> 4) & 0x0F
            let command = portByte & 0x0F
            metadata["port"] = String(port)
            metadata["command"] = String(command)
        }
        log(.verbose, category: "KISS", message: "Frame start (FEND)", endpoint: endpoint, metadata: metadata)
    }
    
    func logKISSFrameEnd(endpoint: String, totalBytes: Int) {
        guard config.logKISSFraming else { return }
        log(
            .verbose,
            category: "KISS",
            message: "Frame end (FEND)",
            endpoint: endpoint,
            metadata: ["frame_size": String(totalBytes)]
        )
    }
    
    func logKISSFrameComplete(endpoint: String, frame: Data, port: Int, command: Int) {
        guard config.logKISSFraming else { return }
        let commandName = kissCommandName(command)
        log(
            .debug,
            category: "KISS",
            message: "Frame complete: \(commandName)",
            endpoint: endpoint,
            data: frame,
            metadata: [
                "port": String(port),
                "command": String(command),
                "size": String(frame.count)
            ]
        )
    }
    
    func logKISSFrameError(endpoint: String, reason: String, partialData: Data? = nil) {
        log(
            .error,
            category: "KISS",
            message: "Frame decode error: \(reason)",
            endpoint: endpoint,
            data: partialData
        )
    }
    
    func logKISSEscapeSequence(endpoint: String, escaped: UInt8, decoded: UInt8) {
        log(
            .verbose,
            category: "KISS",
            message: "Escape sequence: 0x\(String(escaped, radix: 16, uppercase: true)) → 0x\(String(decoded, radix: 16, uppercase: true))",
            endpoint: endpoint
        )
    }
    
    private func kissCommandName(_ command: Int) -> String {
        switch command {
        case 0: return "DATA"
        case 1: return "TXDELAY"
        case 2: return "PERSISTENCE"
        case 3: return "SLOTTIME"
        case 4: return "TXTAIL"
        case 5: return "FULLDUPLEX"
        case 6: return "SETHARDWARE"
        case 0x0C: return "MOBILINKD_GET_ALL_VALUES"
        case 0x0D: return "MOBILINKD_SET_ALL_VALUES"
        default: return "UNKNOWN(\(command))"
        }
    }
    
    // MARK: - AX.25 Diagnostics
    
    func logAX25FrameReceived(
        endpoint: String,
        source: String,
        destination: String,
        control: UInt8,
        info: Data?,
        rawFrame: Data
    ) {
        guard config.logAX25Parsing else { return }
        
        let frameType = ax25FrameType(control: control)
        var metadata: [String: String] = [
            "src": source,
            "dst": destination,
            "type": frameType,
            "control": String(format: "0x%02X", control)
        ]
        
        if let info {
            metadata["info_size"] = String(info.count)
        }
        
        log(
            .info,
            category: "AX.25",
            message: "Frame: \(source) → \(destination) (\(frameType))",
            endpoint: endpoint,
            data: rawFrame,
            metadata: metadata
        )
        
        trackReception(endpoint: endpoint, bytes: rawFrame.count)
    }
    
    func logAX25ParseError(endpoint: String, reason: String, rawData: Data) {
        log(
            .error,
            category: "AX.25",
            message: "Parse error: \(reason)",
            endpoint: endpoint,
            data: rawData
        )
    }
    
    func logAX25FrameSent(
        endpoint: String,
        source: String,
        destination: String,
        control: UInt8,
        dataSize: Int
    ) {
        guard config.logAX25Parsing else { return }
        let frameType = ax25FrameType(control: control)
        log(
            .info,
            category: "AX.25",
            message: "TX: \(source) → \(destination) (\(frameType))",
            endpoint: endpoint,
            metadata: [
                "type": frameType,
                "control": String(format: "0x%02X", control),
                "size": String(dataSize)
            ]
        )
    }
    
    private func ax25FrameType(control: UInt8) -> String {
        if (control & 0x01) == 0 {
            // I-frame
            let ns = (control >> 1) & 0x07
            let nr = (control >> 5) & 0x07
            return "I(N(S)=\(ns), N(R)=\(nr))"
        } else if (control & 0x03) == 0x01 {
            // S-frame
            let type = (control >> 2) & 0x03
            let nr = (control >> 5) & 0x07
            let typeStr: String
            switch type {
            case 0: typeStr = "RR"
            case 1: typeStr = "RNR"
            case 2: typeStr = "REJ"
            case 3: typeStr = "SREJ"
            default: typeStr = "S?"
            }
            return "\(typeStr)(N(R)=\(nr))"
        } else {
            // U-frame
            let modifier = control & 0xEF
            switch modifier {
            case 0x03, 0x2F: return "SABM"
            case 0x43, 0x63: return "DISC"
            case 0x0F, 0x63: return "DM"
            case 0x63, 0x73: return "UA"
            case 0x87: return "FRMR"
            case 0x03: return "UI"
            case 0xAF: return "XID"
            case 0xE3: return "TEST"
            default: return "U(\(String(format: "0x%02X", modifier)))"
            }
        }
    }
    
    // MARK: - Reception Tracking
    
    private func trackReception(endpoint: String, bytes: Int) {
        let now = Date()
        
        // Check for reception gap
        if config.detectReceptionGaps {
            if let lastTime = lastReceptionTime[endpoint] {
                let gap = now.timeIntervalSince(lastTime)
                if gap > config.receptionGapThreshold {
                    log(
                        .warning,
                        category: "Reception",
                        message: "⏱️ RECEPTION GAP DETECTED",
                        endpoint: endpoint,
                        metadata: [
                            "gap_duration": String(format: "%.2f", gap),
                            "threshold": String(format: "%.2f", config.receptionGapThreshold)
                        ]
                    )
                }
            }
        }
        
        lastReceptionTime[endpoint] = now
        receptionCount[endpoint, default: 0] += 1
        totalBytesReceived[endpoint, default: 0] += bytes
        
        if config.logPacketTimestamps {
            let uptime = now.timeIntervalSince(sessionStartTime)
            log(
                .debug,
                category: "Reception",
                message: "Packet #\(receptionCount[endpoint] ?? 0)",
                endpoint: endpoint,
                metadata: [
                    "timestamp": String(format: "%.3f", uptime),
                    "bytes": String(bytes),
                    "total_bytes": String(totalBytesReceived[endpoint] ?? 0)
                ]
            )
        }
    }
    
    func logReceptionSummary(endpoint: String) {
        let count = receptionCount[endpoint] ?? 0
        let bytes = totalBytesReceived[endpoint] ?? 0
        let uptime = Date().timeIntervalSince(sessionStartTime)
        
        log(
            .info,
            category: "Reception",
            message: "Summary",
            endpoint: endpoint,
            metadata: [
                "packets": String(count),
                "bytes": String(bytes),
                "uptime": String(format: "%.1f", uptime),
                "rate": count > 0 ? String(format: "%.2f pkt/s", Double(count) / uptime) : "0"
            ]
        )
    }
    
    // MARK: - Performance Timing
    
    func startTiming(_ operation: String) {
        guard config.enablePerformanceTiming else { return }
        operationStartTimes[operation] = Date()
    }
    
    func endTiming(_ operation: String, endpoint: String? = nil) {
        guard config.enablePerformanceTiming else { return }
        guard let startTime = operationStartTimes[operation] else { return }
        
        let duration = Date().timeIntervalSince(startTime)
        operationStartTimes.removeValue(forKey: operation)
        
        log(
            .debug,
            category: "Performance",
            message: "⏱️ \(operation)",
            endpoint: endpoint,
            metadata: [
                "duration_ms": String(format: "%.3f", duration * 1000)
            ]
        )
    }
    
    // MARK: - General Diagnostics
    
    func logInfo(_ message: String, endpoint: String? = nil, metadata: [String: String] = [:]) {
        log(.info, category: "General", message: message, endpoint: endpoint, metadata: metadata)
    }
    
    func logWarning(_ message: String, endpoint: String? = nil, metadata: [String: String] = [:]) {
        log(.warning, category: "General", message: message, endpoint: endpoint, metadata: metadata)
    }
    
    func logError(_ message: String, endpoint: String? = nil, metadata: [String: String] = [:]) {
        log(.error, category: "General", message: message, endpoint: endpoint, metadata: metadata)
    }
    
    func logDebug(_ message: String, endpoint: String? = nil, metadata: [String: String] = [:]) {
        log(.debug, category: "General", message: message, endpoint: endpoint, metadata: metadata)
    }
    
    // MARK: - Utilities
    
    private func hexDump(_ data: Data) -> String {
        var result = "Hex dump (\(data.count) bytes):\n"
        var offset = 0
        
        while offset < data.count {
            // Offset
            result += String(format: "%04X: ", offset)
            
            // Hex bytes
            let lineEnd = min(offset + 16, data.count)
            for i in offset..<lineEnd {
                result += String(format: "%02X ", data[i])
                if i == offset + 7 {
                    result += " "
                }
            }
            
            // Padding for incomplete line
            if lineEnd - offset < 16 {
                let missing = 16 - (lineEnd - offset)
                result += String(repeating: "   ", count: missing)
                if lineEnd - offset < 8 {
                    result += " "
                }
            }
            
            // ASCII representation
            result += " |"
            for i in offset..<lineEnd {
                let byte = data[i]
                if byte >= 32 && byte <= 126 {
                    result += String(format: "%c", byte)
                } else {
                    result += "."
                }
            }
            result += "|\n"
            
            offset = lineEnd
        }
        
        return result
    }
}

// MARK: - Convenience Extensions

extension AX25DiagnosticLogger {
    /// Quick access to shared logger with async/await
    static func log(_ level: AX25DiagnosticLevel, _ message: String, endpoint: String? = nil) {
        Task {
            await shared.log(level, category: "General", message: message, endpoint: endpoint)
        }
    }
}
