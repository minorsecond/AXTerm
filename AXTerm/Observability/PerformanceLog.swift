//
//  PerformanceLog.swift
//  AXTerm
//
//  Created by AXTerm on 2026-02-08.
//

import Foundation
import OSLog

/// Centralized signpost loggers for performance instrumentation.
/// Use these with `OSSignposter` API to measure intervals in Instruments.
enum PerformanceLog {
    /// Signposter for UI view updates and rendering
    static let viewUpdate = OSSignposter(subsystem: "AXTerm", category: "ViewUpdate")
    
    /// Signposter for packet processing pipeline (KISS -> AX.25 -> Payload)
    static let packetProcessing = OSSignposter(subsystem: "AXTerm", category: "PacketProcessing")
    
    /// Signposter for database operations
    static let db = OSSignposter(subsystem: "AXTerm", category: "Database")
    
    /// Signposter for transmission operations
    static let transmission = OSSignposter(subsystem: "AXTerm", category: "Transmission")
}
