import XCTest
@testable import AXTerm

@MainActor
final class AX25AdversarialTests: XCTestCase {
    
    private let local = AX25Address(call: "NOCALL", ssid: 0)
    private let peer = AX25Address(call: "ADVERS-1", ssid: 0)
    private let path = DigiPath([])
    
    private func makeManager() -> AX25SessionManager {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        return manager
    }

    /// Phase 3: REJ Storm Testing
    /// Verifies the stack does not crash or infinite loop when a peer sends an endless stream of REJs
    func testREJStormHandling() {
        let manager = makeManager()
        _ = manager.connect(to: peer, path: path, channel: 0)
        manager.handleInboundUA(from: peer, path: path, channel: 0)
        
        let session = manager.session(for: peer, path: path, channel: 0)
        XCTAssertEqual(session.state, AX25SessionState.connected)
        
        // Send a frame
        _ = manager.sendData(Data("Target".utf8), to: peer, path: path, channel: 0)
        
        // Subject to REJ storm
        for _ in 0..<100 {
            _ = manager.handleInboundREJ(from: peer, path: path, channel: 0, nr: 0)
        }
        
        // Assert session survived and constraints are met
        XCTAssertEqual(session.state, AX25SessionState.connected)
        XCTAssertEqual(session.outstandingCount, 1) // Our single frame is still outstanding
    }
    
    /// Phase 3: Partial Window ACK Recovery
    /// Test that receiving ACKs for the middle of a window correctly drains send buffers and updates V(A)
    func testPartialWindowACKRecovery() {
        let manager = makeManager()
        manager.defaultConfig = AX25SessionConfig(windowSize: 4)
        _ = manager.connect(to: peer, path: path, channel: 0)
        manager.handleInboundUA(from: peer, path: path, channel: 0)
        
        let session = manager.session(for: peer, path: path, channel: 0)
        
        _ = manager.sendData(Data("Frame0".utf8), to: peer, path: path, channel: 0)
        _ = manager.sendData(Data("Frame1".utf8), to: peer, path: path, channel: 0)
        _ = manager.sendData(Data("Frame2".utf8), to: peer, path: path, channel: 0)
        _ = manager.sendData(Data("Frame3".utf8), to: peer, path: path, channel: 0)
        
        XCTAssertEqual(session.outstandingCount, 4)
        
        // Peer acks up to 2 (acks frame 0 and 1)
        _ = manager.handleInboundRR(from: peer, path: path, channel: 0, nr: 2, isPoll: false)
        
        XCTAssertEqual(session.va, 2)
        XCTAssertEqual(session.outstandingCount, 2) // frames 2 and 3 remain
        XCTAssertEqual(session.sendBuffer.count, 2)
    }

    /// Phase 3: DISC + DATA Collision
    /// Peer sends DISC while we are transmitting DATA, or we send DISC while they send DATA.
    func testDISCDataCollision() {
        let manager = makeManager()
        _ = manager.connect(to: peer, path: path, channel: 0)
        manager.handleInboundUA(from: peer, path: path, channel: 0)
        let session = manager.session(for: peer, path: path, channel: 0)
        
        // We disconnect
        _ = manager.disconnect(session: session)
        XCTAssertEqual(session.state, AX25SessionState.disconnecting)
        
        // In the meantime, peer sent us an I-Frame (collision)
        _ = manager.handleInboundIFrame(from: peer, path: path, channel: 0, ns: 0, nr: 0, pf: false, payload: Data("Too late".utf8))
        
        // State should still be disconnecting, and frame should be ignored
        XCTAssertEqual(session.state, AX25SessionState.disconnecting)
    }
    
    /// Phase 3: Duplicate SABM Handling
    /// Peer maliciously or accidentally repeatedly sends SABM during an active connection.
    func testDuplicateSABMHandling() {
        let manager = makeManager()
        _ = manager.connect(to: peer, path: path, channel: 0)
        manager.handleInboundUA(from: peer, path: path, channel: 0)
        
        let session = manager.session(for: peer, path: path, channel: 0)
        _ = manager.sendData(Data("Hello".utf8), to: peer, path: path, channel: 0)
        XCTAssertEqual(session.vs, 1)
        
        // Receive duplicate SABM
        let uaFrame = manager.handleInboundSABM(from: peer, to: local, path: path, channel: 0)
        
        XCTAssertNotNil(uaFrame) // We must acknowledge it with UA
        XCTAssertEqual(uaFrame?.frameType, "u")
        
        // Connection is reset!
        XCTAssertEqual(session.state, AX25SessionState.connected)
        XCTAssertEqual(session.vs, 0)
        XCTAssertEqual(session.vr, 0)
        XCTAssertEqual(session.outstandingCount, 0)
    }
    
    /// Phase 3: Duplicate Frame Suppression
    /// Peer sends the same I-Frame repeatedly, we should only deliver it to app once and ack it.
    func testDuplicateFrameSuppression() {
        let manager = makeManager()
        _ = manager.connect(to: peer, path: path, channel: 0)
        manager.handleInboundUA(from: peer, path: path, channel: 0)
        
        var receivedCount = 0
        manager.onDataReceived = { _, _ in
            receivedCount += 1
        }
        
        // Receive same frame 3 times
        for _ in 0..<3 {
            _ = manager.handleInboundIFrame(from: peer, path: path, channel: 0, ns: 0, nr: 0, pf: false, payload: Data("Dupe".utf8))
        }
        
        // Should only be delivered once!
        XCTAssertEqual(receivedCount, 1)
        
        let session = manager.session(for: peer, path: path, channel: 0)
        XCTAssertEqual(session.vr, 1) // V(R) advanced once
    }
}
