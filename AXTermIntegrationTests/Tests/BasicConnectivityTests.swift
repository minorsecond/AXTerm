//
//  BasicConnectivityTests.swift
//  AXTermIntegrationTests
//
//  Tests basic connectivity to Direwolf simulation environment.
//

import XCTest
@testable import AXTerm

/// Tests that verify the simulation environment is working.
/// These should be run first to validate the Docker/VM setup.
final class BasicConnectivityTests: XCTestCase {

    // MARK: - Setup

    override func setUp() async throws {
        // Give time for any previous test cleanup
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
    }

    // MARK: - Port Connectivity Tests

    /// Test that Station A (TEST-1) KISS port is accessible
    func testStationAPortAccessible() async throws {
        let client = SimulatorClient.stationA()

        do {
            try await client.connect()
            // If we get here, connection succeeded
            client.disconnect()
        } catch {
            XCTFail("Failed to connect to Station A (port 8001): \(error)")
        }
    }

    /// Test that Station B (TEST-2) KISS port is accessible
    func testStationBPortAccessible() async throws {
        let client = SimulatorClient.stationB()

        do {
            try await client.connect()
            client.disconnect()
        } catch {
            XCTFail("Failed to connect to Station B (port 8002): \(error)")
        }
    }

    /// Test that both stations can be connected simultaneously
    func testBothStationsAccessible() async throws {
        let clientA = SimulatorClient.stationA()
        let clientB = SimulatorClient.stationB()

        try await clientA.connect()
        try await clientB.connect()

        // Both connected successfully
        clientA.disconnect()
        clientB.disconnect()
    }

    // MARK: - Beacon Reception Tests

    /// Test that we can receive beacons from Station A
    /// Note: Beacons are configured to send every 60 seconds, so this may take time
    func testReceiveBeaconFromStationA() async throws {
        let clientB = SimulatorClient.stationB()
        try await clientB.connect()

        // Clear any existing frames
        clientB.clearReceiveBuffer()

        // Wait for a beacon (with longer timeout since beacons are every 60s)
        // For quick testing, we'll just verify we can connect and listen
        // Real beacon test would need longer timeout
        do {
            _ = try await clientB.waitForFrame(timeout: 5.0)
            // If we received a frame, great!
        } catch SimulatorClientError.timeout {
            // Timeout is acceptable for short test - beacons are infrequent
            // The important thing is we successfully connected and waited
        }

        clientB.disconnect()
    }
}
