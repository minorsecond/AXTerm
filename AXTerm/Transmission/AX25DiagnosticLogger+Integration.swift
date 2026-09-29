//
//  AX25DiagnosticLogger+Integration.swift
//  AXTerm
//
//  Helper extensions for integrating AX25DiagnosticLogger into existing code.
//

import Foundation
import CoreBluetooth

// MARK: - Data Extension for KISS Analysis

extension Data {
    /// Extract KISS port and command from the first byte (assumes FEND already stripped)
    var kissPortAndCommand: (port: Int, command: Int)? {
        guard !isEmpty else { return nil }
        let firstByte = self[0]
        let port = Int((firstByte >> 4) & 0x0F)
        let command = Int(firstByte & 0x0F)
        return (port, command)
    }
    
    /// Check if data starts with KISS FEND byte
    var startsWithKISSFend: Bool {
        !isEmpty && self[0] == 0xC0
    }
    
    /// Check if data ends with KISS FEND byte
    var endsWithKISSFend: Bool {
        !isEmpty && self[count - 1] == 0xC0
    }
    
    /// Count KISS FEND bytes in data
    var kissFrameBoundaryCount: Int {
        filter { $0 == 0xC0 }.count
    }
}

// MARK: - CBCharacteristic Extension

extension CBCharacteristic {
    /// Human-readable property description
    var propertiesDescription: String {
        var props: [String] = []
        if properties.contains(.read) { props.append("read") }
        if properties.contains(.write) { props.append("write") }
        if properties.contains(.writeWithoutResponse) { props.append("writeNoResp") }
        if properties.contains(.notify) { props.append("notify") }
        if properties.contains(.indicate) { props.append("indicate") }
        if properties.contains(.broadcast) { props.append("broadcast") }
        if properties.contains(.authenticatedSignedWrites) { props.append("signedWrite") }
        if properties.contains(.extendedProperties) { props.append("extended") }
        return props.joined(separator: "|")
    }
}

// MARK: - Integration Helpers

/// Quick logging for BLE operations
enum BLEDiagnostic {
    /// Log service discovery
    static func serviceDiscovered(
        endpoint: String,
        service: CBService
    ) {
        let isKnown = BLEServiceUUIDs.knownTNCServices.contains(service.uuid)
        Task {
            await AX25DiagnosticLogger.shared.logBLEServiceDiscovered(
                endpoint: endpoint,
                serviceUUID: service.uuid.uuidString,
                isKnownService: isKnown
            )
        }
    }
    
    /// Log characteristic discovery
    static func characteristicDiscovered(
        endpoint: String,
        service: CBService,
        characteristic: CBCharacteristic
    ) {
        Task {
            await AX25DiagnosticLogger.shared.logBLECharacteristicDiscovered(
                endpoint: endpoint,
                serviceUUID: service.uuid.uuidString,
                characteristicUUID: characteristic.uuid.uuidString,
                properties: characteristic.propertiesDescription
            )
        }
    }
    
    /// Log characteristic selection
    static func characteristicSelected(
        endpoint: String,
        role: String,
        characteristic: CBCharacteristic,
        priority: Int,
        reason: String
    ) {
        Task {
            await AX25DiagnosticLogger.shared.logBLECharacteristicSelected(
                endpoint: endpoint,
                role: role,
                characteristicUUID: characteristic.uuid.uuidString,
                priority: priority,
                reason: reason
            )
        }
    }
    
    /// Log characteristic override (THE BUG!)
    static func characteristicOverride(
        endpoint: String,
        role: String,
        oldCharacteristic: CBCharacteristic,
        newCharacteristic: CBCharacteristic,
        reason: String
    ) {
        Task {
            await AX25DiagnosticLogger.shared.logBLECharacteristicOverride(
                endpoint: endpoint,
                role: role,
                oldUUID: oldCharacteristic.uuid.uuidString,
                newUUID: newCharacteristic.uuid.uuidString,
                reason: reason
            )
        }
    }
    
    /// Log subscription change
    static func subscriptionChanged(
        endpoint: String,
        characteristic: CBCharacteristic,
        enabled: Bool,
        error: Error? = nil
    ) {
        Task {
            await AX25DiagnosticLogger.shared.logBLESubscriptionChange(
                endpoint: endpoint,
                characteristicUUID: characteristic.uuid.uuidString,
                enabled: enabled,
                success: error == nil,
                error: error?.localizedDescription
            )
        }
    }
    
    /// Log filtered data (wrong characteristic)
    static func dataFiltered(
        endpoint: String,
        receivedFrom: CBCharacteristic,
        expected: CBCharacteristic,
        data: Data
    ) {
        Task {
            await AX25DiagnosticLogger.shared.logBLEDataFiltered(
                endpoint: endpoint,
                characteristicUUID: receivedFrom.uuid.uuidString,
                expectedUUID: expected.uuid.uuidString,
                dataSize: data.count
            )
        }
    }
}

/// Quick logging for KISS operations
enum KISSDiagnostic {
    /// Log complete KISS frame
    static func frameComplete(
        endpoint: String,
        frame: Data,
        port: Int,
        command: Int
    ) {
        Task {
            await AX25DiagnosticLogger.shared.logKISSFrameComplete(
                endpoint: endpoint,
                frame: frame,
                port: port,
                command: command
            )
        }
    }
    
    /// Log KISS frame error
    static func frameError(
        endpoint: String,
        reason: String,
        partialData: Data? = nil
    ) {
        Task {
            await AX25DiagnosticLogger.shared.logKISSFrameError(
                endpoint: endpoint,
                reason: reason,
                partialData: partialData
            )
        }
    }
    
    /// Log frame boundaries
    static func frameBoundary(
        endpoint: String,
        isStart: Bool,
        portByte: UInt8? = nil,
        totalBytes: Int? = nil
    ) {
        Task {
            if isStart {
                await AX25DiagnosticLogger.shared.logKISSFrameStart(
                    endpoint: endpoint,
                    portByte: portByte
                )
            } else if let totalBytes {
                await AX25DiagnosticLogger.shared.logKISSFrameEnd(
                    endpoint: endpoint,
                    totalBytes: totalBytes
                )
            }
        }
    }
}

/// Quick logging for AX.25 operations
enum AX25Diagnostic {
    /// Log received frame
    static func frameReceived(
        endpoint: String,
        source: String,
        destination: String,
        control: UInt8,
        info: Data?,
        rawFrame: Data
    ) {
        Task {
            await AX25DiagnosticLogger.shared.logAX25FrameReceived(
                endpoint: endpoint,
                source: source,
                destination: destination,
                control: control,
                info: info,
                rawFrame: rawFrame
            )
        }
    }
    
    /// Log parse error
    static func parseError(
        endpoint: String,
        reason: String,
        rawData: Data
    ) {
        Task {
            await AX25DiagnosticLogger.shared.logAX25ParseError(
                endpoint: endpoint,
                reason: reason,
                rawData: rawData
            )
        }
    }
    
    /// Log sent frame
    static func frameSent(
        endpoint: String,
        source: String,
        destination: String,
        control: UInt8,
        dataSize: Int
    ) {
        Task {
            await AX25DiagnosticLogger.shared.logAX25FrameSent(
                endpoint: endpoint,
                source: source,
                destination: destination,
                control: control,
                dataSize: dataSize
            )
        }
    }
}

// MARK: - Quick Configuration

extension AX25DiagnosticLogger {
    /// Enable comprehensive debugging for issue diagnosis
    static func enableDebugMode() {
        Task {
            await shared.updateConfig(.comprehensive)
            await shared.logInfo("🔍 Comprehensive diagnostic logging enabled")
        }
    }
    
    /// Enable standard logging for production
    static func enableStandardMode() {
        Task {
            await shared.updateConfig(.standard)
        }
    }
    
    /// Disable verbose logging
    static func enableMinimalMode() {
        Task {
            await shared.updateConfig(.minimal)
        }
    }
}

// MARK: - BLE Service UUIDs Extension (for diagnostic helper)

extension BLEServiceUUIDs {
    /// Check if a service UUID is known
    static func isKnown(_ uuid: CBUUID) -> Bool {
        knownTNCServices.contains(uuid)
    }
}
