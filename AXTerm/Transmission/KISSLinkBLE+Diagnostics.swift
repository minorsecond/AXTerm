//
//  KISSLinkBLE+Diagnostics.swift
//  AXTerm
//
//  Diagnostic logging integration points for KISSLinkBLE.
//  This file shows the specific locations where diagnostic logging
//  should be added to catch the characteristic override bug and
//  other BLE/KISS/AX.25 issues.
//

import Foundation
import CoreBluetooth

// MARK: - Integration Points

/*
 
 This file documents where to add diagnostic logging calls in KISSLinkBLE.swift.
 Copy these code snippets into the appropriate locations.
 
 */

// MARK: - 1. Service Discovery

/*
 In: peripheral(_:didDiscoverServices:)
 After: "BLE discovered X services" log
 
 Add:
 */
extension KISSLinkBLE {
    func logServiceDiscovery(_ services: [CBService]) {
        for service in services {
            BLEDiagnostic.serviceDiscovered(
                endpoint: endpointDescription,
                service: service
            )
        }
    }
}

// MARK: - 2. Characteristic Discovery

/*
 In: peripheral(_:didDiscoverCharacteristicsFor:error:)
 After: characteristics are discovered
 
 Add:
 */
extension KISSLinkBLE {
    func logCharacteristicDiscovery(_ service: CBService) {
        for characteristic in service.characteristics ?? [] {
            BLEDiagnostic.characteristicDiscovered(
                endpoint: endpointDescription,
                service: service,
                characteristic: characteristic
            )
        }
    }
}

// MARK: - 3. Characteristic Selection with Override Detection

/*
 In: selectBestCharacteristics()
 When setting txCharacteristic/rxCharacteristic
 
 Add BEFORE assignment:
 */
extension KISSLinkBLE {
    func logCharacteristicSelection(
        _ characteristic: CBCharacteristic,
        role: String,
        priority: Int,
        reason: String
    ) {
        // Check for override (THE BUG!)
        lock.lock()
        let existingTX = txCharacteristic
        let existingRX = rxCharacteristic
        lock.unlock()
        
        if role == "TX" && existingTX != nil {
            BLEDiagnostic.characteristicOverride(
                endpoint: endpointDescription,
                role: role,
                oldCharacteristic: existingTX!,
                newCharacteristic: characteristic,
                reason: reason
            )
        } else if role == "RX" && existingRX != nil {
            BLEDiagnostic.characteristicOverride(
                endpoint: endpointDescription,
                role: role,
                oldCharacteristic: existingRX!,
                newCharacteristic: characteristic,
                reason: reason
            )
        } else {
            // Normal selection
            BLEDiagnostic.characteristicSelected(
                endpoint: endpointDescription,
                role: role,
                characteristic: characteristic,
                priority: priority,
                reason: reason
            )
        }
    }
}

// MARK: - 4. Subscription Changes

/*
 In: peripheral(_:didUpdateNotificationStateFor:error:)
 Replace existing log with:
 */
extension KISSLinkBLE {
    func logSubscriptionChange(
        _ characteristic: CBCharacteristic,
        error: Error?
    ) {
        BLEDiagnostic.subscriptionChanged(
            endpoint: endpointDescription,
            characteristic: characteristic,
            enabled: characteristic.isNotifying,
            error: error
        )
    }
}

// MARK: - 5. Data Reception with Filtering

/*
 In: peripheral(_:didUpdateValueFor:error:)
 When filtering wrong characteristic, replace existing error log with:
 */
extension KISSLinkBLE {
    func logDataFiltering(
        receivedFrom: CBCharacteristic,
        expected: CBCharacteristic,
        data: Data
    ) {
        BLEDiagnostic.dataFiltered(
            endpoint: endpointDescription,
            receivedFrom: receivedFrom,
            expected: expected,
            data: data
        )
    }
}

// MARK: - 6. KISS Frame Processing

/*
 When decoding KISS frames (in linkDidReceive or KISS decoder)
 
 Add:
 */
extension KISSLinkBLE {
    func logKISSFrame(_ data: Data) {
        // Check for frame boundaries
        if data.startsWithKISSFend {
            KISSDiagnostic.frameBoundary(
                endpoint: endpointDescription,
                isStart: true,
                portByte: data.count > 1 ? data[1] : nil
            )
        }
        
        // After successful decode
        if let (port, command) = data.kissPortAndCommand {
            KISSDiagnostic.frameComplete(
                endpoint: endpointDescription,
                frame: data,
                port: port,
                command: command
            )
        }
    }
    
    func logKISSError(reason: String, data: Data) {
        KISSDiagnostic.frameError(
            endpoint: endpointDescription,
            reason: reason,
            partialData: data
        )
    }
}

// MARK: - Complete Example: Modified didUpdateValueFor

/*
 Here's a complete example of how to modify didUpdateValueFor with diagnostics:
 */

extension KISSLinkBLE {
    func peripheral_withDiagnostics(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            Task {
                await AX25DiagnosticLogger.shared.logError(
                    "BLE RX error: \(error.localizedDescription)",
                    endpoint: endpointDescription
                )
            }
            return
        }
        
        guard let data = characteristic.value, !data.isEmpty else { return }
        
        // Check if this is the expected characteristic
        lock.lock()
        let currentRx = rxCharacteristic
        lock.unlock()
        
        if let currentRx, characteristic.uuid != currentRx.uuid {
            // DATA FILTERING - This is the smoking gun for the bug!
            logDataFiltering(
                receivedFrom: characteristic,
                expected: currentRx,
                data: data
            )
            return
        }
        
        // Log successful reception
        lock.lock()
        _totalBytesIn += data.count
        lock.unlock()
        
        // Log KISS frame if configured
        logKISSFrame(data)
        
        // Continue with normal processing
        Task { @MainActor [weak self] in
            self?.delegate?.linkDidReceive(data)
        }
    }
}

// MARK: - Complete Example: Modified selectBestCharacteristics

extension KISSLinkBLE {
    func selectBestCharacteristics_withDiagnostics() {
        var bestTX: (char: CBCharacteristic, priority: Int)?
        var bestRX: (char: CBCharacteristic, priority: Int)?
        
        lock.lock()
        let allChars = discoveredServiceCharacteristics
        lock.unlock()
        
        for (serviceUUID, characteristics) in allChars {
            let isKnownService = BLEServiceUUIDs.knownTNCServices.contains(serviceUUID)
            
            for char in characteristics {
                switch char.uuid {
                case BLECharacteristicUUIDs.mobilinkdTX,
                     BLECharacteristicUUIDs.nordicUARTRX:
                    if bestTX == nil || bestTX!.priority < 3 {
                        // Check for override before assigning
                        logCharacteristicSelection(
                            char,
                            role: "TX",
                            priority: 3,
                            reason: "Known service UUID match"
                        )
                        bestTX = (char, 3)
                    }
                    
                case BLECharacteristicUUIDs.mobilinkdRX,
                     BLECharacteristicUUIDs.nordicUARTTX:
                    if bestRX == nil || bestRX!.priority < 3 {
                        logCharacteristicSelection(
                            char,
                            role: "RX",
                            priority: 3,
                            reason: "Known service UUID match"
                        )
                        bestRX = (char, 3)
                    }
                    
                default:
                    // Heuristic selection
                    let isWritable = char.properties.contains(.write) ||
                                   char.properties.contains(.writeWithoutResponse)
                    let isNotifiable = char.properties.contains(.notify)
                    let heuristicPriority = isKnownService ? 2 : 1
                    
                    if isWritable && (bestTX == nil || bestTX!.priority < heuristicPriority) {
                        logCharacteristicSelection(
                            char,
                            role: "TX",
                            priority: heuristicPriority,
                            reason: "Heuristic (writable)"
                        )
                        bestTX = (char, heuristicPriority)
                    }
                    
                    if isNotifiable && (bestRX == nil || bestRX!.priority < heuristicPriority) {
                        logCharacteristicSelection(
                            char,
                            role: "RX",
                            priority: heuristicPriority,
                            reason: "Heuristic (notifiable)"
                        )
                        bestRX = (char, heuristicPriority)
                    }
                }
            }
        }
        
        guard let tx = bestTX?.char, let rx = bestRX?.char else {
            Task {
                await AX25DiagnosticLogger.shared.logError(
                    "No suitable TX/RX characteristics found",
                    endpoint: endpointDescription
                )
            }
            return
        }
        
        lock.lock()
        txCharacteristic = tx
        rxCharacteristic = rx
        lock.unlock()
    }
}

// MARK: - Usage Instructions

/*
 
 TO INTEGRATE:
 
 1. Add the diagnostic calls at the appropriate locations in KISSLinkBLE.swift:
 
    - In peripheral(_:didDiscoverServices:), call logServiceDiscovery()
    - In peripheral(_:didDiscoverCharacteristicsFor:), call logCharacteristicDiscovery()
    - In selectBestCharacteristics(), add logCharacteristicSelection() before assignments
    - In peripheral(_:didUpdateNotificationStateFor:), call logSubscriptionChange()
    - In peripheral(_:didUpdateValueFor:), call logDataFiltering() when filtering
    - In KISS frame processing, call logKISSFrame() and logKISSError()
 
 2. Enable diagnostic logging at app startup:
 
    AX25DiagnosticLogger.enableDebugMode()  // For debugging
    AX25DiagnosticLogger.enableStandardMode()  // For production
 
 3. View logs in Console.app:
 
    Subsystem: com.rosswardrup.AXTerm
    Category: AX25Diagnostics
 
 4. Look for key indicators:
 
    ⚠️ CHARACTERISTIC OVERRIDE - The bug is happening!
    🚫 DATA FILTERED - Wrong characteristic receiving data
    ⏱️ RECEPTION GAP - Packets stopped
 
 With these logs, you can diagnose:
 - The characteristic override bug
 - Reception stoppage
 - KISS frame errors
 - BLE connection issues
 - And any other AX.25/BLE problems
 
 */
