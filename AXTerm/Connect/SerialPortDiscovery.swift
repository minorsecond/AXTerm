//
//  SerialPortDiscovery.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/14/26.
//

import Foundation
import Combine

/// Represents a discovered serial port device
struct SerialDevice: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let name: String
    
    // Friendly display name (e.g. "TNC4Mobilinkd" instead of "cu.TNC4Mobilinkd")
    var displayName: String {
        name
    }
    
    // Whether the device is currently present in the system
    var isAvailable: Bool = true
    
    // Mobilinkd TNC4 Configuration
    var mobilinkdConfig: MobilinkdConfig?
}

/// Actor responsible for discovering serial ports on the system.
/// Uses `FileManager` to enumerate `/dev/cu.*` devices, which is sufficient for macOS
/// and simpler than IOKit for basic enumeration, while still respecting sandbox if entitlements are present.
@MainActor
final class SerialPortDiscovery: ObservableObject {
    @Published private(set) var devices: [SerialDevice] = []
    
    private var timer: Timer?
    private let fileManager = FileManager.default
    
    // Known system ports to ignore to reduce noise
    private let ignoredPatterns = [
        "Bluetooth-Incoming-Port",
        "debug-console",
        "wlan-debug"
    ]
    
    @MainActor
    func startScanning(interval: TimeInterval = 2.0) {
        Task { await refresh() }
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.refresh()
            }
        }
    }
    
    @MainActor
    func stopScanning() {
        timer?.invalidate()
        timer = nil
    }
    
    private func refresh() async {
        let discovered = await performDiscovery()
        
        // Update on main actor (since we are in @MainActor class, this method is isolated, but performDiscovery is not)
        // Wait, if refresh is on MainActor, we can just assign.
        if discovered != devices {
            devices = discovered
        }
    }
    
    nonisolated private func performDiscovery() async -> [SerialDevice] {
        do {
            let devContents = try fileManager.contentsOfDirectory(atPath: "/dev")
            
            let ports = devContents.filter { filename in
                // We only want calling units (cu.*) for outbound connections
                // tty.* devices block on open if DCD is not asserted, which hangs the app
                guard filename.hasPrefix("cu.") else { return false }
                
                // Filter out known system noise
                for pattern in ignoredPatterns {
                    if filename.contains(pattern) { return false }
                }
                
                return true
            }
            
            return ports.map { filename in
                let path = "/dev/\(filename)"
                // Remove "cu." prefix for display
                let name = String(filename.dropFirst(3))
                return SerialDevice(id: path, path: path, name: name)
            }.sorted { $0.name < $1.name }
            
        } catch {
            print("SerialPortDiscovery: Failed to list /dev: \(error)")
            return []
        }
    }
}
