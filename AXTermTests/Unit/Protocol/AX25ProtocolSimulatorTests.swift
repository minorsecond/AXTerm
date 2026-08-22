//
//  AX25ProtocolSimulatorTests.swift
//  AXTermTests
//
//  Tests to verify the simulation infrastructure correctly connects
//  nodes and handles standard AX.25 sessions under various conditions.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25ProtocolSimulatorTests: XCTestCase {
    
    func testPerfectLinkConnectionAndDataTransfer() async throws {
        let sim = AX25ProtocolSimulator()
        sim.baseLatency = 0.01 // Very fast for tests
        sim.jitter = 0.005
        sim.dropProbability = 0.0
        
        let nodeA = AX25SimulatorNode(callsign: "N0CALL", ssid: 1)
        let nodeB = AX25SimulatorNode(callsign: "K0CALL", ssid: 1)
        
        sim.addNode(nodeA)
        sim.addNode(nodeB)
        
        // Node A initiates connection to Node B
        if let sabm = nodeA.manager.connect(to: nodeB.callsign, path: DigiPath(), channel: 0) {
            nodeA.manager.onSendFrame?(sabm)
        }
        
        // Wait for the SABM -> UA exchange. Fixed sleeps flake under full-suite
        // parallel load: the simulator delivers frames via unstructured
        // Task { Task.sleep } hops, so on a saturated cooperative pool a 100 ms
        // window is not a guarantee. Poll with a generous deadline instead.
        let sessionA = nodeA.manager.session(for: nodeB.callsign, path: DigiPath(), channel: 0)
        try await waitUntil("both nodes connected") {
            sessionA.state == .connected &&
            nodeB.manager.sessions.values.first(where: { $0.remoteAddress == nodeA.callsign })?.state == .connected
        }

        let sessionB = nodeB.manager.sessions.values.first(where: { $0.remoteAddress == nodeA.callsign })
        XCTAssertEqual(sessionA.state, .connected, "Node A should be connected")
        XCTAssertNotNil(sessionB, "Node B should have created a session")
        XCTAssertEqual(sessionB?.state, .connected, "Node B should be connected")
        
        // Node A sends data
        let testData = Data("Hello, Node B!".utf8)
        let frames = nodeA.manager.sendData(testData, to: nodeB.callsign, path: DigiPath(), channel: 0)
        for frame in frames {
            nodeA.manager.onSendFrame?(frame)
        }
        
        // Wait for I-frame delivery and RR ack
        try await waitUntil("data delivered and acknowledged") {
            sessionA.outstandingCount == 0 &&
            sessionB?.stateMachine.sequenceState.vr == 1
        }

        XCTAssertEqual(sessionA.outstandingCount, 0, "Node A should have received an ACK")
        XCTAssertEqual(sessionB?.stateMachine.sequenceState.vr, 1, "Node B should have received the frame and incremented V(R)")
    }

    /// Poll `condition` every 20 ms until it holds or `deadline` seconds elapse.
    /// Returns normally either way — the caller's assertions produce the failure
    /// detail. The deadline only bounds the wait.
    private func waitUntil(
        _ label: String,
        deadline: TimeInterval = 5.0,
        condition: @escaping () -> Bool
    ) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    
    func testLossyLinkRetransmitsAndEventuallyConnects() async throws {
        let sim = AX25ProtocolSimulator()
        sim.baseLatency = 0.01
        sim.jitter = 0.0
        sim.dropProbability = 0.3 // 30% loss rate gives ~99.9% chance of success over 10 retries
        
        let nodeA = AX25SimulatorNode(callsign: "N0CALL", ssid: 2)
        let nodeB = AX25SimulatorNode(callsign: "K0CALL", ssid: 2)
        
        sim.addNode(nodeA)
        sim.addNode(nodeB)
        
        let sessionA = nodeA.manager.session(for: nodeB.callsign, path: DigiPath(), channel: 0)
        sessionA.timers = AX25SessionTimers(rtoMin: 0.05, rtoMax: 0.1, initialRto: 0.05)
        
        if let sabm = nodeA.manager.connect(to: nodeB.callsign, path: DigiPath(), channel: 0) {
            nodeA.manager.onSendFrame?(sabm)
        }
        
        // Wait long enough for several T1 timeouts and SABM retransmits
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5s
        
        // sessionA already declared above
        
        // Given enough time and default N2=10, an 80% loss rate means we have a ~98% chance
        // of AT LEAST ONE SABM making it through and AT LEAST ONE UA making it back.
        // The probability of both succeeding consecutively within 10 tries is very high.
        print("[DEBUG] Session A state: \(sessionA.state), retries: \(sessionA.stateMachine.retryCount)")
        XCTAssertEqual(sessionA.state, .connected, "Node A should have eventually connected despite heavy loss")
    }
}
