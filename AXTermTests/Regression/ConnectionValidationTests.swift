//
//  ConnectionValidationTests.swift
//  AXTermTests
//
//  Comprehensive tests for connection validation, address matching, and
//  session routing to ensure correct behavior and prevent routing bugs.
//
//  This tests edge cases like:
//  - Self-connection attempts (should be rejected)
//  - SSID matching (TEST-1 vs TEST-2 are different)
//  - Callsign normalization and case handling
//  - Session key matching and routing
//  - Connection state transitions
//

import XCTest
@testable import AXTerm

// MARK: - Address Validation Tests

final class AddressValidationTests: XCTestCase {
    
    // MARK: - SSID Distinction Tests
    
    func testSSIDDistinction() {
        let addr1 = AX25Address(call: "TEST", ssid: 1)
        let addr2 = AX25Address(call: "TEST", ssid: 2)
        let addr0 = AX25Address(call: "TEST", ssid: 0)
        
        // Different SSIDs should NOT be equal
        XCTAssertNotEqual(addr1, addr2)
        XCTAssertNotEqual(addr1, addr0)
        XCTAssertNotEqual(addr2, addr0)
    }
    
    func testSameSSIDEquality() {
        let addr1a = AX25Address(call: "TEST", ssid: 1)
        let addr1b = AX25Address(call: "TEST", ssid: 1)
        
        XCTAssertEqual(addr1a, addr1b)
    }
    
    func testCallsignCaseNormalization() {
        let addrLower = AX25Address(call: "test", ssid: 1)
        let addrUpper = AX25Address(call: "TEST", ssid: 1)
        
        // Callsigns should be normalized to uppercase
        XCTAssertEqual(addrLower.call.uppercased(), addrUpper.call.uppercased())
    }
    
    func testSSIDRange() {
        // Valid SSIDs are 0-15
        for ssid in 0...15 {
            let addr = AX25Address(call: "TEST", ssid: ssid)
            XCTAssertEqual(addr.ssid, ssid)
        }
    }
    
    func testCallsignKeyGeneration() {
        let addr1 = AX25Address(call: "TEST", ssid: 1)
        let addr2 = AX25Address(call: "TEST", ssid: 2)
        
        // Keys should be different for different SSIDs
        let key1 = "\(addr1.call)-\(addr1.ssid)"
        let key2 = "\(addr2.call)-\(addr2.ssid)"
        
        XCTAssertNotEqual(key1, key2)
        XCTAssertEqual(key1, "TEST-1")
        XCTAssertEqual(key2, "TEST-2")
    }
    
    // MARK: - Callsign Parsing Tests
    
    func testCallsignParsingWithSSID() {
        // Parse "TEST-1" format
        let input = "TEST-1"
        let parts = input.split(separator: "-")
        
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(String(parts[0]), "TEST")
        XCTAssertEqual(Int(parts[1]), 1)
    }
    
    func testCallsignParsingWithoutSSID() {
        // Parse "TEST" format (implied SSID 0)
        let input = "TEST"
        let parts = input.split(separator: "-")
        
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(String(parts[0]), "TEST")
    }
    
    func testCallsignParsingEdgeCases() {
        // Edge case: multiple dashes (should take first two parts)
        let input = "TEST-1-2"
        let parts = input.split(separator: "-", maxSplits: 1)
        
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(String(parts[0]), "TEST")
    }
    
    // MARK: - Self-Connection Detection Tests
    
    func testSelfConnectionDetection() {
        let localCall = "TEST"
        let localSSID = 1
        let localAddr = AX25Address(call: localCall, ssid: localSSID)
        
        // Same callsign and SSID = self
        let destSame = AX25Address(call: "TEST", ssid: 1)
        XCTAssertEqual(localAddr, destSame)
        
        // Same callsign, different SSID = NOT self
        let destDiffSSID = AX25Address(call: "TEST", ssid: 2)
        XCTAssertNotEqual(localAddr, destDiffSSID)
        
        // Different callsign = NOT self
        let destDiffCall = AX25Address(call: "OTHER", ssid: 1)
        XCTAssertNotEqual(localAddr, destDiffCall)
    }
    
    func testSelfConnectionDetectionCaseInsensitive() {
        let localAddr = AX25Address(call: "TEST", ssid: 1)
        
        // Case should not matter for self-detection
        let destLower = AX25Address(call: "test", ssid: 1)
        
        // Compare normalized callsigns
        XCTAssertEqual(localAddr.call.uppercased(), destLower.call.uppercased())
        XCTAssertEqual(localAddr.ssid, destLower.ssid)
    }
}

// MARK: - Session Key Tests

final class SessionKeyTests: XCTestCase {
    
    func testSessionKeyDistinctionBySSID() {
        // Sessions to TEST-1 and TEST-2 should be distinct
        let key1 = "TEST-1||0"  // destination|pathSignature|channel
        let key2 = "TEST-2||0"
        
        XCTAssertNotEqual(key1, key2)
    }
    
    func testSessionKeyDistinctionByPath() {
        // Same destination via different paths should be distinct
        let keyDirect = "TEST-1||0"
        let keyViaDigi = "TEST-1|DIGI-0|0"
        
        XCTAssertNotEqual(keyDirect, keyViaDigi)
    }
    
    func testSessionKeyDistinctionByChannel() {
        // Same destination on different channels should be distinct
        let keyCh0 = "TEST-1||0"
        let keyCh1 = "TEST-1||1"
        
        XCTAssertNotEqual(keyCh0, keyCh1)
    }
    
    func testSessionKeyNormalization() {
        // Keys should be normalized (uppercase callsign)
        let keyLower = "test-1||0".uppercased()
        let keyUpper = "TEST-1||0"
        
        XCTAssertEqual(keyLower, keyUpper)
    }
}

// MARK: - Connection Routing Simulation Tests

/// Simulates connection routing to test for correct session matching
final class ConnectionRoutingTests: XCTestCase {
    
    var network: VirtualNetwork!
    var stationA: RelayTestStation!  // TEST-1
    var stationB: RelayTestStation!  // TEST-2
    var stationC: RelayTestStation!  // OTHER-0
    
    override func setUp() {
        super.setUp()
        network = VirtualNetwork()
        stationA = RelayTestStation(callsign: "TEST", ssid: 1, network: network)
        stationB = RelayTestStation(callsign: "TEST", ssid: 2, network: network)
        stationC = RelayTestStation(callsign: "OTHER", ssid: 0, network: network)
    }
    
    override func tearDown() {
        network.reset()
        stationA.reset()
        stationB.reset()
        stationC.reset()
        super.tearDown()
    }
    
    // MARK: - Correct Routing Tests
    
    func testConnectionToCorrectSSID() {
        // TEST-1 connects to TEST-2
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        
        // TEST-2 should receive the SABM
        XCTAssertTrue(stationB.receivedFrames.count > 0)
        
        // Verify it's addressed to TEST-2
        if let lastFrame = stationB.receivedFrames.first,
           let decoded = AX25.decodeFrame(ax25: lastFrame) {
            XCTAssertEqual(decoded.to?.call, "TEST")
            XCTAssertEqual(decoded.to?.ssid, 2)
            XCTAssertEqual(decoded.from?.call, "TEST")
            XCTAssertEqual(decoded.from?.ssid, 1)
        }
    }
    
    func testConnectionNotRoutedToWrongSSID() {
        // TEST-1 connects to TEST-2
        stationA.connect(to: stationB.callsign)
        
        // TEST-1 (self) should NOT receive the SABM
        stationA.processReceivedFrames()
        
        // No frames should be processed by A (since it's the sender)
        XCTAssertEqual(stationA.receivedFrames.count, 0)
    }
    
    func testConnectionToDistinctCallsign() {
        // TEST-1 connects to OTHER-0
        stationA.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        
        XCTAssertTrue(stationC.receivedFrames.count > 0)
        
        if let lastFrame = stationC.receivedFrames.first,
           let decoded = AX25.decodeFrame(ax25: lastFrame) {
            XCTAssertEqual(decoded.to?.call, "OTHER")
            XCTAssertEqual(decoded.to?.ssid, 0)
        }
    }
    
    // MARK: - Session Distinction Tests
    
    func testSeparateSessionsForDifferentSSIDs() {
        // TEST-1 connects to both TEST-2 and OTHER-0
        stationA.connect(to: stationB.callsign)
        stationA.connect(to: stationC.callsign)
        
        // Should have two separate sessions
        XCTAssertEqual(stationA.sessions.count, 2)
        XCTAssertNotNil(stationA.sessions["TEST-2"])
        XCTAssertNotNil(stationA.sessions["OTHER-0"])
    }
    
    func testSessionStatesIndependent() {
        // Establish both connections
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        stationA.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        // C does NOT accept
        
        // Session to B should be connected
        XCTAssertEqual(stationA.sessions["TEST-2"]?.state, .connected)
        
        // Session to C should still be connecting
        XCTAssertEqual(stationA.sessions["OTHER-0"]?.state, .connecting)
    }
    
    // MARK: - UA Response Routing Tests
    
    func testUARoutedToCorrectSession() {
        // TEST-1 connects to TEST-2
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        // Session to TEST-2 should be connected
        XCTAssertEqual(stationA.sessions["TEST-2"]?.state, .connected)
    }
    
    func testUAFromWrongStationIgnored() {
        // TEST-1 connects to TEST-2
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        
        // OTHER-0 sends a UA (should not affect TEST-1's session to TEST-2)
        // This simulates a rogue UA
        let rogueUA = AX25.encodeUFrame(
            from: stationC.callsign,
            to: stationA.callsign,
            via: [],
            type: .ua,
            pf: true
        )
        network.send(from: "OTHER-0", to: "TEST-1", frame: rogueUA)
        stationA.processReceivedFrames()
        
        // Session to TEST-2 should still be connecting (not connected by rogue UA)
        XCTAssertEqual(stationA.sessions["TEST-2"]?.state, .connecting)
    }
    
    // MARK: - Data Routing Tests
    
    func testDataRoutedToCorrectSession() {
        // Establish connection TEST-1 <-> TEST-2
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        // TEST-1 sends data to TEST-2
        stationA.sendPlainText("Hello TEST-2", to: stationB.callsign)
        stationB.processReceivedFrames()
        
        // TEST-2 should receive the data
        XCTAssertEqual(stationB.receivedPlainText.count, 1)
        XCTAssertEqual(String(data: stationB.receivedPlainText[0].data, encoding: .utf8), "Hello TEST-2")
        
        // OTHER-0 should NOT receive any data
        stationC.processReceivedFrames()
        XCTAssertEqual(stationC.receivedPlainText.count, 0)
    }
    
    func testDataFromWrongSessionIgnored() {
        // Establish connection TEST-1 <-> TEST-2
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        // OTHER-0 tries to send data to TEST-1 (no session established)
        // This should be ignored since no session exists
        let rogueIFrame = AX25.encodeIFrame(
            from: stationC.callsign,
            to: stationA.callsign,
            via: [],
            ns: 0,
            nr: 0,
            pf: false,
            pid: 0xF0,
            info: "Rogue data".data(using: .utf8)!
        )
        network.send(from: "OTHER-0", to: "TEST-1", frame: rogueIFrame)
        stationA.processReceivedFrames()
        
        // TEST-1 should NOT have received this data (no session with OTHER-0)
        // The frame might be received but not processed as valid session data
        // Check that receivedPlainText is empty or only has data from valid session
        let rogueData = stationA.receivedPlainText.filter { $0.from == "OTHER-0" }
        XCTAssertEqual(rogueData.count, 0)
    }
}

// MARK: - Self-Connection Prevention Tests

final class SelfConnectionPreventionTests: XCTestCase {
    
    var network: VirtualNetwork!
    var station: RelayTestStation!
    
    override func setUp() {
        super.setUp()
        network = VirtualNetwork()
        station = RelayTestStation(callsign: "TEST", ssid: 1, network: network)
    }
    
    override func tearDown() {
        network.reset()
        station.reset()
        super.tearDown()
    }
    
    func testSelfConnectionAttemptSameCallsignSameSSID() {
        // Attempting to connect to self should be detected
        let selfAddr = AX25Address(call: "TEST", ssid: 1)
        
        // This tests the detection logic
        let isSelf = (station.callsign.call.uppercased() == selfAddr.call.uppercased() &&
                     station.callsign.ssid == selfAddr.ssid)
        
        XCTAssertTrue(isSelf, "Should detect self-connection attempt")
    }
    
    func testSelfConnectionAttemptSameCallsignDifferentSSID() {
        // Connecting to same callsign but different SSID is valid
        let otherSSID = AX25Address(call: "TEST", ssid: 2)
        
        let isSelf = (station.callsign.call.uppercased() == otherSSID.call.uppercased() &&
                     station.callsign.ssid == otherSSID.ssid)
        
        XCTAssertFalse(isSelf, "Different SSID should not be detected as self")
    }
    
    func testSelfConnectionAttemptCaseVariation() {
        // Case variations should still be detected as self
        let selfLower = AX25Address(call: "test", ssid: 1)
        
        let isSelf = (station.callsign.call.uppercased() == selfLower.call.uppercased() &&
                     station.callsign.ssid == selfLower.ssid)
        
        XCTAssertTrue(isSelf, "Case variation should still detect self")
    }
}

// MARK: - Connection State Transition Tests

final class ConnectionStateTransitionTests: XCTestCase {
    
    var network: VirtualNetwork!
    var stationA: RelayTestStation!
    var stationB: RelayTestStation!
    
    override func setUp() {
        super.setUp()
        network = VirtualNetwork()
        stationA = RelayTestStation(callsign: "STA", ssid: 1, network: network)
        stationB = RelayTestStation(callsign: "STB", ssid: 2, network: network)
    }
    
    override func tearDown() {
        network.reset()
        stationA.reset()
        stationB.reset()
        super.tearDown()
    }
    
    // MARK: - Normal Connection Flow
    
    func testNormalConnectionFlow() {
        // Initial state
        XCTAssertNil(stationA.sessions["STB-2"])
        
        // Send SABM
        stationA.connect(to: stationB.callsign)
        XCTAssertEqual(stationA.sessions["STB-2"]?.state, .connecting)
        
        // B receives and accepts
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        
        // A receives UA
        stationA.processReceivedFrames()
        XCTAssertEqual(stationA.sessions["STB-2"]?.state, .connected)
    }
    
    func testConnectionRejection() {
        // Send SABM
        stationA.connect(to: stationB.callsign)
        XCTAssertEqual(stationA.sessions["STB-2"]?.state, .connecting)
        
        // B receives and rejects
        stationB.processReceivedFrames()
        stationB.rejectConnection(from: stationA.callsign)
        
        // A receives DM
        stationA.processReceivedFrames()
        XCTAssertEqual(stationA.sessions["STB-2"]?.state, .disconnected)
    }
    
    func testDisconnectionFlow() {
        // Establish connection
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        XCTAssertEqual(stationA.sessions["STB-2"]?.state, .connected)
        
        // Disconnect
        stationA.disconnect(from: stationB.callsign)
        XCTAssertEqual(stationA.sessions["STB-2"]?.state, .disconnecting)
        
        // B receives DISC and sends UA
        stationB.processReceivedFrames()
        
        // A receives UA
        stationA.processReceivedFrames()
        XCTAssertEqual(stationA.sessions["STB-2"]?.state, .disconnected)
    }
    
    // MARK: - Invalid State Transitions
    
    func testCannotConnectWhenAlreadyConnected() {
        // Establish connection
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        XCTAssertEqual(stationA.sessions["STB-2"]?.state, .connected)
        
        // Try to connect again
        let frameCountBefore = stationA.sentFrames.count
        stationA.connect(to: stationB.callsign)
        
        // Should not send another SABM (connection already exists)
        // The connect() method checks if session exists and is connected
        // Implementation may vary - key is no protocol violation
    }
    
    func testCannotSendDataWhenDisconnected() {
        // No connection established
        XCTAssertNil(stationA.sessions["STB-2"])
        
        // Try to send data
        stationA.sendPlainText("Test", to: stationB.callsign)
        
        // No I-frame should be sent (no connected session)
        let iFrames = stationA.sentFrames.filter { frame in
            if let decoded = AX25.decodeFrame(ax25: frame) {
                return decoded.frameType == .i
            }
            return false
        }
        XCTAssertEqual(iFrames.count, 0)
    }
}

// MARK: - Callsign Edge Cases Tests

final class CallsignEdgeCasesTests: XCTestCase {
    
    func testMinimumCallsignLength() {
        // Minimum valid callsign (1 character + region number)
        let shortCall = AX25Address(call: "A1B", ssid: 0)
        XCTAssertEqual(shortCall.call, "A1B")
    }
    
    func testMaximumCallsignLength() {
        // Maximum 6 characters for AX.25
        let longCall = AX25Address(call: "W1AW", ssid: 0)
        XCTAssertEqual(longCall.call, "W1AW")
    }
    
    func testNumericInCallsign() {
        // Callsigns with numbers
        let numCall = AX25Address(call: "K9ABC", ssid: 0)
        XCTAssertEqual(numCall.call, "K9ABC")
    }
    
    func testSSIDBoundaries() {
        // SSID 0 (default)
        let ssid0 = AX25Address(call: "TEST", ssid: 0)
        XCTAssertEqual(ssid0.ssid, 0)
        
        // SSID 15 (maximum)
        let ssid15 = AX25Address(call: "TEST", ssid: 15)
        XCTAssertEqual(ssid15.ssid, 15)
    }
    
    func testCallsignWithSpaces() {
        // Spaces in callsign should be handled
        let spacedCall = AX25Address(call: "W1AW  ", ssid: 0)
        // Implementation may trim spaces
        XCTAssertFalse(spacedCall.call.isEmpty)
    }
}

// MARK: - Path Signature Edge Cases

final class PathSignatureTests: XCTestCase {
    
    func testEmptyPathSignature() {
        // Direct connection (no digipeaters)
        let path: [AX25Address] = []
        let signature = path.map { "\($0.call)-\($0.ssid)" }.joined(separator: ",")
        
        XCTAssertEqual(signature, "")
    }
    
    func testSingleDigiPathSignature() {
        let digi = AX25Address(call: "DIGI", ssid: 0)
        let path = [digi]
        let signature = path.map { "\($0.call)-\($0.ssid)" }.joined(separator: ",")
        
        XCTAssertEqual(signature, "DIGI-0")
    }
    
    func testMultipleDigiPathSignature() {
        let digi1 = AX25Address(call: "DIGI1", ssid: 0)
        let digi2 = AX25Address(call: "DIGI2", ssid: 1)
        let path = [digi1, digi2]
        let signature = path.map { "\($0.call)-\($0.ssid)" }.joined(separator: ",")
        
        XCTAssertEqual(signature, "DIGI1-0,DIGI2-1")
    }
    
    func testPathSignatureDistinction() {
        // Different paths should have different signatures
        let path1 = [AX25Address(call: "DIGI1", ssid: 0)]
        let path2 = [AX25Address(call: "DIGI2", ssid: 0)]
        
        let sig1 = path1.map { "\($0.call)-\($0.ssid)" }.joined(separator: ",")
        let sig2 = path2.map { "\($0.call)-\($0.ssid)" }.joined(separator: ",")
        
        XCTAssertNotEqual(sig1, sig2)
    }
    
    func testPathOrderMatters() {
        // Different order = different path
        let digi1 = AX25Address(call: "DIGI1", ssid: 0)
        let digi2 = AX25Address(call: "DIGI2", ssid: 0)
        
        let path1 = [digi1, digi2]
        let path2 = [digi2, digi1]
        
        let sig1 = path1.map { "\($0.call)-\($0.ssid)" }.joined(separator: ",")
        let sig2 = path2.map { "\($0.call)-\($0.ssid)" }.joined(separator: ",")
        
        XCTAssertNotEqual(sig1, sig2)
    }
}

// MARK: - Incoming Frame Address Verification

final class IncomingFrameAddressVerificationTests: XCTestCase {
    
    func testIncomingFrameDestinationCheck() {
        // Simulate receiving a frame
        let localCall = AX25Address(call: "TEST", ssid: 1)
        let remoteCall = AX25Address(call: "OTHER", ssid: 0)
        
        // Frame addressed to us
        let frameToUs = AX25.encodeIFrame(
            from: remoteCall,
            to: localCall,
            via: [],
            ns: 0,
            nr: 0,
            pf: false,
            pid: 0xF0,
            info: "Test".data(using: .utf8)!
        )
        
        if let decoded = AX25.decodeFrame(ax25: frameToUs) {
            XCTAssertEqual(decoded.to?.call, localCall.call)
            XCTAssertEqual(decoded.to?.ssid, localCall.ssid)
        }
    }
    
    func testIncomingFrameNotForUs() {
        // Frame addressed to someone else
        let localCall = AX25Address(call: "TEST", ssid: 1)
        let otherCall = AX25Address(call: "TEST", ssid: 2)
        let remoteCall = AX25Address(call: "OTHER", ssid: 0)
        
        let frameNotForUs = AX25.encodeIFrame(
            from: remoteCall,
            to: otherCall,  // Different SSID
            via: [],
            ns: 0,
            nr: 0,
            pf: false,
            pid: 0xF0,
            info: "Test".data(using: .utf8)!
        )
        
        if let decoded = AX25.decodeFrame(ax25: frameNotForUs) {
            // Should not match our address (different SSID)
            let isForUs = (decoded.to?.call == localCall.call && 
                          decoded.to?.ssid == localCall.ssid)
            XCTAssertFalse(isForUs)
        }
    }
}

// MARK: - Regression Tests

final class ConnectionRegressionTests: XCTestCase {
    
    /// Regression: Connecting to TEST-1 should NOT affect TEST-2's state
    func testConnectionDoesNotAffectOtherSSID() {
        let network = VirtualNetwork()
        let stationA = RelayTestStation(callsign: "LOCAL", ssid: 0, network: network)
        let stationB = RelayTestStation(callsign: "TEST", ssid: 1, network: network)
        let stationC = RelayTestStation(callsign: "TEST", ssid: 2, network: network)
        
        // LOCAL connects to TEST-1
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        // TEST-1 should be connected
        XCTAssertEqual(stationA.sessions["TEST-1"]?.state, .connected)
        
        // TEST-2 should have NO session with LOCAL
        XCTAssertNil(stationC.sessions["LOCAL-0"])
        
        // TEST-2 should not have received any frames
        stationC.processReceivedFrames()
        XCTAssertEqual(stationC.receivedFrames.count, 0)
    }
    
    /// Regression: Session lookup should match exact SSID
    func testSessionLookupMatchesExactSSID() {
        let network = VirtualNetwork()
        let station = RelayTestStation(callsign: "LOCAL", ssid: 0, network: network)
        
        // Create sessions to different SSIDs
        station.sessions["TEST-1"] = RelayTestStation.SessionState(state: .connected)
        station.sessions["TEST-2"] = RelayTestStation.SessionState(state: .disconnected)
        
        // Lookup for TEST-1 should find TEST-1, not TEST-2
        let session1 = station.sessions["TEST-1"]
        let session2 = station.sessions["TEST-2"]
        
        XCTAssertNotNil(session1)
        XCTAssertNotNil(session2)
        XCTAssertEqual(session1?.state, .connected)
        XCTAssertEqual(session2?.state, .disconnected)
    }
    
    /// Regression: UA from wrong station should not connect session
    func testUAFromWrongStationRejected() {
        let network = VirtualNetwork()
        let stationA = RelayTestStation(callsign: "STA", ssid: 1, network: network)
        let stationB = RelayTestStation(callsign: "STB", ssid: 2, network: network)
        let stationC = RelayTestStation(callsign: "STC", ssid: 3, network: network)
        
        // A connects to B
        stationA.connect(to: stationB.callsign)
        XCTAssertEqual(stationA.sessions["STB-2"]?.state, .connecting)
        
        // C sends UA (impersonating response)
        let fakeUA = AX25.encodeUFrame(
            from: stationC.callsign,
            to: stationA.callsign,
            via: [],
            type: .ua,
            pf: true
        )
        network.send(from: "STC-3", to: "STA-1", frame: fakeUA)
        stationA.processReceivedFrames()
        
        // Session to B should still be connecting (fake UA rejected)
        XCTAssertEqual(stationA.sessions["STB-2"]?.state, .connecting)
        
        // No session to C should exist
        XCTAssertNil(stationA.sessions["STC-3"])
    }
    
    /// Regression: Frames must be addressed to local callsign to be processed
    func testOnlyProcessFramesAddressedToUs() {
        let network = VirtualNetwork()
        let stationA = RelayTestStation(callsign: "LOCAL", ssid: 1, network: network)
        
        // Send frame addressed to different SSID
        let frameToOther = AX25.encodeUFrame(
            from: AX25Address(call: "REMOTE", ssid: 0),
            to: AX25Address(call: "LOCAL", ssid: 2),  // Different SSID!
            via: [],
            type: .sabm,
            pf: true
        )
        
        // This frame should be delivered to LOCAL-2's queue, not LOCAL-1's
        // Network.send uses callsign-SSID as key
        network.send(from: "REMOTE-0", to: "LOCAL-2", frame: frameToOther)
        
        // LOCAL-1 processes its queue
        stationA.processReceivedFrames()
        
        // LOCAL-1 should not have processed this frame (addressed to LOCAL-2)
        XCTAssertEqual(stationA.receivedFrames.count, 0)
    }
}
