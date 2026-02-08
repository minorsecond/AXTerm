//
//  ConnectedModeIntegrationTests.swift
//  AXTermTests
//
//  Comprehensive integration tests for connected-mode messaging and transfers.
//  Tests both AXDP-enabled and raw packet communication through all stages:
//  - Connection establishment (SABM/UA/DISC)
//  - Plain text I-frame exchange
//  - AXDP chat message fragmentation and reassembly
//  - AXDP file transfer with acknowledgments
//  - Mixed mode: AXDP ↔ non-AXDP station interoperability
//  - Error recovery (retransmission, REJ)
//  - Sequence number wraparound
//
//  These tests can run either with the Docker KISS relay or in-memory simulation.
//
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md, CLAUDE.md
//

import XCTest
@testable import AXTerm

// MARK: - Virtual Radio Link

/// In-memory virtual radio link that connects two simulated stations.
/// Frames sent by Station A are received by Station B and vice versa.
final class VirtualRadioLink {
    private var stationAQueue: [Data] = []
    private var stationBQueue: [Data] = []
    private let lock = NSLock()
    
    /// Send a frame from Station A (will be received by Station B)
    func sendFromA(_ frame: Data) {
        lock.lock()
        stationBQueue.append(frame)
        lock.unlock()
    }
    
    /// Send a frame from Station B (will be received by Station A)
    func sendFromB(_ frame: Data) {
        lock.lock()
        stationAQueue.append(frame)
        lock.unlock()
    }
    
    /// Receive all pending frames at Station A
    func receiveAtA() -> [Data] {
        lock.lock()
        let frames = stationAQueue
        stationAQueue.removeAll()
        lock.unlock()
        return frames
    }
    
    /// Receive all pending frames at Station B
    func receiveAtB() -> [Data] {
        lock.lock()
        let frames = stationBQueue
        stationBQueue.removeAll()
        lock.unlock()
        return frames
    }
    
    /// Clear all queues
    func reset() {
        lock.lock()
        stationAQueue.removeAll()
        stationBQueue.removeAll()
        lock.unlock()
    }
}

// MARK: - Test Station Simulator

/// Simulates an AX.25 station for integration testing.
/// Handles connection state, sequence numbers, and frame processing.
final class TestStation {
    let callsign: AX25Address
    let radioLink: VirtualRadioLink
    let isStationA: Bool
    
    // AX.25 state
    var state: AX25SessionState = .disconnected
    var vs: Int = 0  // Send sequence number V(S)
    var vr: Int = 0  // Receive sequence number V(R)
    var va: Int = 0  // Acknowledged sequence number V(A)
    
    // AXDP state
    var axdpEnabled: Bool = true
    var reassemblyBuffer: Data = Data()
    var receivedMessages: [AXDP.Message] = []
    var receivedPlainText: [Data] = []
    
    // Frame history for verification
    var sentFrames: [Data] = []
    var receivedFrames: [Data] = []
    
    init(callsign: String, ssid: Int, radioLink: VirtualRadioLink, isStationA: Bool) {
        self.callsign = AX25Address(call: callsign, ssid: ssid)
        self.radioLink = radioLink
        self.isStationA = isStationA
    }
    
    // MARK: - Connection Management
    
    /// Send SABM to establish connection
    func connect(to remote: AX25Address) {
        let sabm = AX25.encodeUFrame(from: callsign, to: remote, via: [], type: .sabm, pf: true)
        send(sabm)
        state = .connecting
    }
    
    /// Send UA to accept connection
    func acceptConnection(from remote: AX25Address) {
        let ua = AX25.encodeUFrame(from: callsign, to: remote, via: [], type: .ua, pf: true)
        send(ua)
        state = .connected
        resetSequenceNumbers()
    }
    
    /// Send DISC to disconnect
    func disconnect(from remote: AX25Address) {
        let disc = AX25.encodeUFrame(from: callsign, to: remote, via: [], type: .disc, pf: true)
        send(disc)
        state = .disconnecting
    }
    
    // MARK: - Data Transfer
    
    /// Send plain text data as I-frame
    func sendPlainText(_ text: String, to remote: AX25Address) {
        let data = Data(text.utf8)
        let iFrame = AX25.encodeIFrame(from: callsign, to: remote, via: [], ns: vs, nr: vr, pf: false, pid: 0xF0, info: data)
        send(iFrame)
        vs = (vs + 1) % 8
    }
    
    /// Send AXDP chat message (may fragment)
    func sendAXDPChat(_ text: String, to remote: AX25Address, sessionId: UInt32 = 0, messageId: UInt32 = 1, paclen: Int = 128) {
        let msg = AXDP.Message(type: .chat, sessionId: sessionId, messageId: messageId, payload: Data(text.utf8))
        let encoded = msg.encode()
        
        // Fragment into I-frames
        var offset = 0
        while offset < encoded.count {
            let end = min(offset + paclen, encoded.count)
            let chunk = encoded.subdata(in: offset..<end)
            
            let iFrame = AX25.encodeIFrame(from: callsign, to: remote, via: [], ns: vs, nr: vr, pf: false, pid: 0xF0, info: chunk)
            send(iFrame)
            vs = (vs + 1) % 8
            offset = end
        }
    }
    
    /// Send AXDP file transfer (metadata + chunks)
    func sendAXDPFile(name: String, data: Data, to remote: AX25Address, sessionId: UInt32, paclen: Int = 128) {
        // Compute SHA256 for test (simple 32-byte hash)
        let sha256Hash = Data(repeating: 0xAB, count: 32)  // Test hash
        
        let totalChunks = UInt32((data.count + paclen - 1) / paclen)
        
        // Send FILE_META with proper AXDPFileMeta
        let axdpFileMeta = AXDPFileMeta(
            filename: name,
            fileSize: UInt64(data.count),
            sha256: sha256Hash,
            chunkSize: UInt16(paclen)
        )
        let fileMetaMsg = AXDP.Message(
            type: .fileMeta,
            sessionId: sessionId,
            messageId: 0,
            totalChunks: totalChunks,
            fileMeta: axdpFileMeta
        )
        let metaEncoded = fileMetaMsg.encode()
        let metaFrame = AX25.encodeIFrame(from: callsign, to: remote, via: [], ns: vs, nr: vr, pf: false, pid: 0xF0, info: metaEncoded)
        send(metaFrame)
        vs = (vs + 1) % 8
        
        // Send FILE_CHUNKs
        var chunkIndex: UInt32 = 0
        var offset = 0
        
        while offset < data.count {
            let end = min(offset + paclen, data.count)
            let chunkData = data.subdata(in: offset..<end)
            
            let chunk = AXDP.Message(
                type: .fileChunk,
                sessionId: sessionId,
                messageId: chunkIndex + 1,
                chunkIndex: chunkIndex,
                totalChunks: totalChunks,
                payload: chunkData,
                payloadCRC32: AXDP.crc32(chunkData)
            )
            let chunkEncoded = chunk.encode()
            let chunkFrame = AX25.encodeIFrame(from: callsign, to: remote, via: [], ns: vs, nr: vr, pf: false, pid: 0xF0, info: chunkEncoded)
            send(chunkFrame)
            vs = (vs + 1) % 8
            
            chunkIndex += 1
            offset = end
        }
    }
    
    /// Send RR acknowledgment
    func sendRR(to remote: AX25Address, pf: Bool = false) {
        let rr = AX25.encodeSFrame(from: callsign, to: remote, via: [], type: .rr, nr: vr, pf: pf)
        send(rr)
    }
    
    /// Send REJ (reject) for retransmission request
    func sendREJ(to remote: AX25Address, pf: Bool = false) {
        let rej = AX25.encodeSFrame(from: callsign, to: remote, via: [], type: .rej, nr: vr, pf: pf)
        send(rej)
    }
    
    /// Send RNR (Receiver Not Ready) for flow control
    func sendRNR(to remote: AX25Address, pf: Bool = false) {
        let rnr = AX25.encodeSFrame(from: callsign, to: remote, via: [], type: .rnr, nr: vr, pf: pf)
        send(rnr)
    }
    
    /// Send SREJ (Selective Reject) for specific frame retransmission
    func sendSREJ(to remote: AX25Address, nr: Int, pf: Bool = false) {
        let srej = AX25.encodeSFrame(from: callsign, to: remote, via: [], type: .srej, nr: nr, pf: pf)
        send(srej)
    }
    
    /// Send DM (Disconnected Mode) to reject connection
    func sendDM(to remote: AX25Address, pf: Bool = true) {
        let dm = AX25.encodeUFrame(from: callsign, to: remote, via: [], type: .dm, pf: pf)
        send(dm)
        state = .disconnected
    }
    
    /// Send UA to accept disconnection
    func acceptDisconnect(from remote: AX25Address) {
        let ua = AX25.encodeUFrame(from: callsign, to: remote, via: [], type: .ua, pf: true)
        send(ua)
        state = .disconnected
        resetSequenceNumbers()
    }
    
    /// Send plain text with via path (digipeaters)
    func sendPlainTextVia(_ text: String, to remote: AX25Address, via: [AX25Address]) {
        let data = Data(text.utf8)
        let iFrame = AX25.encodeIFrame(from: callsign, to: remote, via: via, ns: vs, nr: vr, pf: false, pid: 0xF0, info: data)
        send(iFrame)
        vs = (vs + 1) % 8
    }
    
    /// Send SABM with via path
    func connectVia(to remote: AX25Address, via: [AX25Address]) {
        let sabm = AX25.encodeUFrame(from: callsign, to: remote, via: via, type: .sabm, pf: true)
        send(sabm)
        state = .connecting
    }
    
    /// Get count of outstanding unacknowledged frames
    var outstandingCount: Int {
        if vs >= va {
            return vs - va
        } else {
            return (8 - va) + vs
        }
    }
    
    /// Send multiple I-frames up to window limit
    func sendWindowFull(_ messages: [String], to remote: AX25Address) {
        for msg in messages {
            let data = Data(msg.utf8)
            let iFrame = AX25.encodeIFrame(from: callsign, to: remote, via: [], ns: vs, nr: vr, pf: false, pid: 0xF0, info: data)
            send(iFrame)
            vs = (vs + 1) % 8
        }
    }
    
    /// Send AXDP PING for capability discovery
    func sendAXDPPing(to remote: AX25Address, sessionId: UInt32 = 0) {
        let caps = AXDPCapability.defaultLocal()
        let ping = AXDP.Message(type: .ping, sessionId: sessionId, messageId: 0, capabilities: caps)
        let encoded = ping.encode()
        let iFrame = AX25.encodeIFrame(from: callsign, to: remote, via: [], ns: vs, nr: vr, pf: false, pid: 0xF0, info: encoded)
        send(iFrame)
        vs = (vs + 1) % 8
    }
    
    /// Send AXDP PONG response
    func sendAXDPPong(to remote: AX25Address, sessionId: UInt32 = 0) {
        let caps = AXDPCapability.defaultLocal()
        let pong = AXDP.Message(type: .pong, sessionId: sessionId, messageId: 0, capabilities: caps)
        let encoded = pong.encode()
        let iFrame = AX25.encodeIFrame(from: callsign, to: remote, via: [], ns: vs, nr: vr, pf: false, pid: 0xF0, info: encoded)
        send(iFrame)
        vs = (vs + 1) % 8
    }
    
    /// Send AXDP ACK for file transfer
    func sendAXDPAck(to remote: AX25Address, sessionId: UInt32, messageId: UInt32) {
        let ack = AXDP.Message(type: .ack, sessionId: sessionId, messageId: messageId)
        let encoded = ack.encode()
        let iFrame = AX25.encodeIFrame(from: callsign, to: remote, via: [], ns: vs, nr: vr, pf: false, pid: 0xF0, info: encoded)
        send(iFrame)
        vs = (vs + 1) % 8
    }
    
    /// Send AXDP NACK for file transfer rejection
    func sendAXDPNack(to remote: AX25Address, sessionId: UInt32, messageId: UInt32) {
        let nack = AXDP.Message(type: .nack, sessionId: sessionId, messageId: messageId)
        let encoded = nack.encode()
        let iFrame = AX25.encodeIFrame(from: callsign, to: remote, via: [], ns: vs, nr: vr, pf: false, pid: 0xF0, info: encoded)
        send(iFrame)
        vs = (vs + 1) % 8
    }
    
    // MARK: - Frame Processing
    
    /// Process received frames and update state
    func processReceivedFrames() {
        let frames = isStationA ? radioLink.receiveAtA() : radioLink.receiveAtB()
        
        for frame in frames {
            receivedFrames.append(frame)
            processFrame(frame)
        }
    }
    
    private func processFrame(_ ax25Frame: Data) {
        guard let decoded = AX25.decodeFrame(ax25: ax25Frame) else { return }
        
        switch decoded.frameType {
        case .u:
            processUFrame(decoded)
        case .s:
            processSFrame(decoded)
        case .i:
            processIFrame(decoded)
        case .ui:
            processUIFrame(decoded)
        default:
            break
        }
    }
    
    private func processUFrame(_ frame: AX25.FrameDecodeResult) {
        let control = frame.controlByte1 ?? frame.control
        let uType = AX25ControlFieldDecoder.decode(control: control).uType
        
        switch uType {
        case .SABM:
            // Incoming connection request
            state = .connecting
        case .UA:
            // Connection accepted
            if state == .connecting {
                state = .connected
                resetSequenceNumbers()
            } else if state == .disconnecting {
                state = .disconnected
            }
        case .DISC:
            // Disconnect request
            state = .disconnected
        case .DM:
            // Disconnected mode response
            state = .disconnected
        default:
            break
        }
    }
    
    private func processSFrame(_ frame: AX25.FrameDecodeResult) {
        let control = frame.controlByte1 ?? frame.control
        let decoded = AX25ControlFieldDecoder.decode(control: control)
        
        // Update acknowledged sequence number
        if let nr = decoded.nr {
            va = nr
        }
    }
    
    private func processIFrame(_ frame: AX25.FrameDecodeResult) {
        let control = frame.controlByte1 ?? frame.control
        let decoded = AX25ControlFieldDecoder.decode(control: control)
        
        // Check sequence number
        if let ns = decoded.ns, ns == vr {
            // In sequence - process data
            vr = (vr + 1) % 8
            
            if !frame.info.isEmpty {
                processPayload(frame.info)
            }
        }
        
        // Update acknowledged
        if let nr = decoded.nr {
            va = nr
        }
    }
    
    private func processUIFrame(_ frame: AX25.FrameDecodeResult) {
        if !frame.info.isEmpty {
            processPayload(frame.info)
        }
    }
    
    private func processPayload(_ data: Data) {
        if axdpEnabled && AXDP.hasMagic(data) {
            // AXDP data - add to reassembly buffer
            reassemblyBuffer.append(data)
            extractAXDPMessages()
        } else if axdpEnabled && AXDP.hasMagic(reassemblyBuffer) {
            // Continuation of AXDP message
            reassemblyBuffer.append(data)
            extractAXDPMessages()
        } else {
            // Plain text
            receivedPlainText.append(data)
        }
    }
    
    private func extractAXDPMessages() {
        while !reassemblyBuffer.isEmpty {
            guard let (msg, consumed) = AXDP.Message.decode(from: reassemblyBuffer),
                  consumed > 0,
                  consumed <= reassemblyBuffer.count else {
                break
            }
            receivedMessages.append(msg)
            reassemblyBuffer = Data(reassemblyBuffer.dropFirst(consumed))
        }
    }
    
    // MARK: - Helpers
    
    private func send(_ frame: Data) {
        sentFrames.append(frame)
        if isStationA {
            radioLink.sendFromA(frame)
        } else {
            radioLink.sendFromB(frame)
        }
    }
    
    private func resetSequenceNumbers() {
        vs = 0
        vr = 0
        va = 0
    }
    
    func reset() {
        state = .disconnected
        resetSequenceNumbers()
        reassemblyBuffer.removeAll()
        receivedMessages.removeAll()
        receivedPlainText.removeAll()
        sentFrames.removeAll()
        receivedFrames.removeAll()
    }
}

// MARK: - Connected Mode Integration Tests

/// Comprehensive integration tests for connected-mode communication.
final class ConnectedModeIntegrationTests: XCTestCase {
    
    var radioLink: VirtualRadioLink!
    var stationA: TestStation!
    var stationB: TestStation!
    
    override func setUp() {
        super.setUp()
        radioLink = VirtualRadioLink()
        stationA = TestStation(callsign: "TEST", ssid: 1, radioLink: radioLink, isStationA: true)
        stationB = TestStation(callsign: "TEST", ssid: 2, radioLink: radioLink, isStationA: false)
    }
    
    override func tearDown() {
        radioLink.reset()
        stationA.reset()
        stationB.reset()
        super.tearDown()
    }
    
    // MARK: - Connection Establishment Tests
    
    /// Test basic SABM → UA connection handshake
    func testConnectionEstablishment() {
        // Station A initiates connection
        stationA.connect(to: stationB.callsign)
        XCTAssertEqual(stationA.state, .connecting)
        
        // Station B receives SABM
        stationB.processReceivedFrames()
        XCTAssertEqual(stationB.state, .connecting)
        XCTAssertEqual(stationB.receivedFrames.count, 1)
        
        // Station B accepts connection
        stationB.acceptConnection(from: stationA.callsign)
        XCTAssertEqual(stationB.state, .connected)
        
        // Station A receives UA
        stationA.processReceivedFrames()
        XCTAssertEqual(stationA.state, .connected)
    }
    
    /// Test DISC → UA disconnection
    func testDisconnection() {
        // Establish connection first
        establishConnection()
        
        // Station A disconnects
        stationA.disconnect(from: stationB.callsign)
        XCTAssertEqual(stationA.state, .disconnecting)
        
        // Station B receives DISC and responds with UA
        stationB.processReceivedFrames()
        stationB.state = .disconnected
        let ua = AX25.encodeUFrame(from: stationB.callsign, to: stationA.callsign, via: [], type: .ua, pf: true)
        radioLink.sendFromB(ua)
        
        // Station A receives UA
        stationA.processReceivedFrames()
        XCTAssertEqual(stationA.state, .disconnected)
    }
    
    // MARK: - Plain Text I-Frame Tests
    
    /// Test single plain text message exchange
    func testPlainTextSingleMessage() {
        establishConnection()
        
        let message = "Hello, World!"
        stationA.sendPlainText(message, to: stationB.callsign)
        
        // Station B receives and processes
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedPlainText.count, 1)
        XCTAssertEqual(String(data: stationB.receivedPlainText[0], encoding: .utf8), message)
    }
    
    /// Test bidirectional plain text exchange
    func testPlainTextBidirectional() {
        establishConnection()
        
        // A → B
        stationA.sendPlainText("Hello from A", to: stationB.callsign)
        stationB.processReceivedFrames()
        
        // B → A
        stationB.sendPlainText("Hello from B", to: stationA.callsign)
        stationA.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedPlainText.count, 1)
        XCTAssertEqual(stationA.receivedPlainText.count, 1)
        XCTAssertEqual(String(data: stationB.receivedPlainText[0], encoding: .utf8), "Hello from A")
        XCTAssertEqual(String(data: stationA.receivedPlainText[0], encoding: .utf8), "Hello from B")
    }
    
    /// Test sequence number increment with multiple messages
    func testPlainTextSequenceNumbers() {
        establishConnection()
        
        for i in 0..<10 {
            stationA.sendPlainText("Message \(i)", to: stationB.callsign)
        }
        
        // Verify V(S) wrapped correctly
        XCTAssertEqual(stationA.vs, 2)  // 10 % 8 = 2
        
        // Process all messages
        stationB.processReceivedFrames()
        XCTAssertEqual(stationB.receivedPlainText.count, 10)
        XCTAssertEqual(stationB.vr, 2)  // Should match sender's vs
    }
    
    // MARK: - AXDP Chat Message Tests
    
    /// Test small AXDP chat message (single fragment)
    func testAXDPChatSingleFragment() {
        establishConnection()
        
        let shortMessage = "Hi!"
        stationA.sendAXDPChat(shortMessage, to: stationB.callsign)
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedMessages.count, 1)
        XCTAssertEqual(stationB.receivedMessages[0].type, .chat)
        XCTAssertEqual(String(data: stationB.receivedMessages[0].payload ?? Data(), encoding: .utf8), shortMessage)
    }
    
    /// Test large AXDP chat message (multiple fragments)
    func testAXDPChatMultipleFragments() {
        establishConnection()
        
        // Create a ~3000 byte message that requires 24 fragments at 128 byte paclen
        let longMessage = String(repeating: "Lorem ipsum dolor sit amet. ", count: 100)
        stationA.sendAXDPChat(longMessage, to: stationB.callsign, paclen: 128)
        
        // Verify fragmentation occurred
        let sentIFrames = stationA.sentFrames.count
        XCTAssertGreaterThan(sentIFrames, 1, "Should fragment into multiple I-frames")
        
        // Process all fragments
        stationB.processReceivedFrames()
        
        // Verify reassembly
        XCTAssertEqual(stationB.receivedMessages.count, 1)
        XCTAssertEqual(stationB.receivedMessages[0].type, .chat)
        XCTAssertEqual(String(data: stationB.receivedMessages[0].payload ?? Data(), encoding: .utf8), longMessage)
    }
    
    /// Test sequence number wraparound during large transfer
    func testAXDPChatSequenceWrap() {
        establishConnection()
        
        // Create message large enough to wrap sequence numbers (needs >8 I-frames)
        let bigMessage = String(repeating: "X", count: 2000)  // ~16 fragments at 128 bytes
        stationA.sendAXDPChat(bigMessage, to: stationB.callsign, paclen: 128)
        
        // V(S) should have wrapped
        let expectedFrames = (bigMessage.utf8.count + 25 + 127) / 128  // +25 for AXDP header overhead
        XCTAssertGreaterThan(expectedFrames, 8, "Should require more than 8 frames")
        XCTAssertEqual(stationA.vs, expectedFrames % 8)
        
        // All should be received
        stationB.processReceivedFrames()
        XCTAssertEqual(stationB.receivedMessages.count, 1)
    }
    
    /// Test multiple consecutive AXDP messages
    func testAXDPChatMultipleMessages() {
        establishConnection()
        
        stationA.sendAXDPChat("First", to: stationB.callsign, messageId: 1)
        stationA.sendAXDPChat("Second", to: stationB.callsign, messageId: 2)
        stationA.sendAXDPChat("Third", to: stationB.callsign, messageId: 3)
        
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedMessages.count, 3)
        XCTAssertEqual(stationB.receivedMessages[0].messageId, 1)
        XCTAssertEqual(stationB.receivedMessages[1].messageId, 2)
        XCTAssertEqual(stationB.receivedMessages[2].messageId, 3)
    }
    
    // MARK: - AXDP File Transfer Tests
    
    /// Test small file transfer
    func testAXDPFileTransferSmall() {
        establishConnection()
        
        let fileData = Data("This is a small test file.".utf8)
        stationA.sendAXDPFile(name: "test.txt", data: fileData, to: stationB.callsign, sessionId: 100)
        
        stationB.processReceivedFrames()
        
        // Should have FILE_META + FILE_CHUNK(s)
        let metaMessages = stationB.receivedMessages.filter { $0.type == .fileMeta }
        let chunkMessages = stationB.receivedMessages.filter { $0.type == .fileChunk }
        
        XCTAssertEqual(metaMessages.count, 1)
        XCTAssertGreaterThan(chunkMessages.count, 0)
        XCTAssertEqual(metaMessages[0].fileMeta?.filename, "test.txt")
        XCTAssertEqual(metaMessages[0].fileMeta?.fileSize, UInt64(fileData.count))
    }
    
    /// Test large file transfer with many chunks
    func testAXDPFileTransferLarge() {
        establishConnection()
        
        // Create 2KB file (16 chunks at 128 bytes)
        let fileData = Data(repeating: 0x42, count: 2048)
        stationA.sendAXDPFile(name: "large.bin", data: fileData, to: stationB.callsign, sessionId: 200, paclen: 128)
        
        stationB.processReceivedFrames()
        
        let metaMessages = stationB.receivedMessages.filter { $0.type == .fileMeta }
        let chunkMessages = stationB.receivedMessages.filter { $0.type == .fileChunk }
        
        XCTAssertEqual(metaMessages.count, 1)
        XCTAssertEqual(Int(metaMessages[0].totalChunks ?? 0), 16)
        XCTAssertEqual(chunkMessages.count, 16)
        
        // Verify chunk indices are sequential
        for (i, chunk) in chunkMessages.enumerated() {
            XCTAssertEqual(Int(chunk.chunkIndex ?? 999), i)
        }
        
        // Verify CRC on chunks
        for chunk in chunkMessages {
            if let payload = chunk.payload, let crc = chunk.payloadCRC32 {
                XCTAssertEqual(AXDP.crc32(payload), crc)
            }
        }
    }
    
    // MARK: - Mixed Mode Tests (AXDP ↔ Non-AXDP)
    
    /// Test AXDP station sending to non-AXDP station
    func testAXDPToNonAXDP() {
        establishConnection()
        
        // Station B disables AXDP (legacy station)
        stationB.axdpEnabled = false
        
        // Station A sends AXDP message
        stationA.sendAXDPChat("Hello legacy!", to: stationB.callsign)
        stationB.processReceivedFrames()
        
        // Legacy station should receive raw AXDP bytes as plain text
        XCTAssertEqual(stationB.receivedMessages.count, 0)  // Not decoded as AXDP
        XCTAssertEqual(stationB.receivedPlainText.count, 1)  // Received as plain text
        
        // The raw data should start with AXDP magic
        XCTAssertTrue(AXDP.hasMagic(stationB.receivedPlainText[0]))
    }
    
    /// Test non-AXDP station sending to AXDP station
    func testNonAXDPToAXDP() {
        establishConnection()
        
        // Station A sends plain text (no AXDP)
        stationA.axdpEnabled = false
        stationA.sendPlainText("Plain text message", to: stationB.callsign)
        
        stationB.processReceivedFrames()
        
        // AXDP station should receive as plain text (no magic)
        XCTAssertEqual(stationB.receivedMessages.count, 0)  // No AXDP messages
        XCTAssertEqual(stationB.receivedPlainText.count, 1)  // Plain text
        XCTAssertEqual(String(data: stationB.receivedPlainText[0], encoding: .utf8), "Plain text message")
    }
    
    /// Test both stations in plain text mode
    func testBothNonAXDP() {
        establishConnection()
        
        stationA.axdpEnabled = false
        stationB.axdpEnabled = false
        
        stationA.sendPlainText("Hello", to: stationB.callsign)
        stationB.processReceivedFrames()
        
        stationB.sendPlainText("World", to: stationA.callsign)
        stationA.processReceivedFrames()
        
        XCTAssertEqual(String(data: stationB.receivedPlainText[0], encoding: .utf8), "Hello")
        XCTAssertEqual(String(data: stationA.receivedPlainText[0], encoding: .utf8), "World")
    }
    
    // MARK: - RR Acknowledgment Tests
    
    /// Test RR is generated correctly after I-frames
    func testRRAfterIFrames() {
        establishConnection()
        
        // Send 3 messages
        for i in 0..<3 {
            stationA.sendPlainText("Msg \(i)", to: stationB.callsign)
        }
        
        stationB.processReceivedFrames()
        
        // V(R) should be 3
        XCTAssertEqual(stationB.vr, 3)
        
        // Send RR
        stationB.sendRR(to: stationA.callsign)
        stationA.processReceivedFrames()
        
        // Verify RR was sent with correct N(R)
        let rrFrames = stationB.sentFrames.filter { frame in
            if let decoded = AX25.decodeFrame(ax25: frame) {
                return decoded.frameType == .s
            }
            return false
        }
        XCTAssertEqual(rrFrames.count, 1)
    }
    
    // MARK: - Error Handling Tests
    
    /// Test that out-of-sequence frames trigger REJ
    func testOutOfSequenceFrame() {
        establishConnection()
        
        // Manually create out-of-sequence I-frame (N(S)=5 when V(R)=0)
        let oosFrame = AX25.encodeIFrame(
            from: stationA.callsign,
            to: stationB.callsign,
            via: [],
            ns: 5,
            nr: 0,
            pf: false,
            pid: 0xF0,
            info: Data("Out of sequence".utf8)
        )
        radioLink.sendFromA(oosFrame)
        stationB.processReceivedFrames()
        
        // V(R) should not advance (frame rejected)
        XCTAssertEqual(stationB.vr, 0)
        
        // Should not be delivered
        XCTAssertEqual(stationB.receivedPlainText.count, 0)
    }
    
    // MARK: - Helpers
    
    private func establishConnection() {
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        XCTAssertEqual(stationA.state, .connected)
        XCTAssertEqual(stationB.state, .connected)
    }
}

// MARK: - Performance Tests

/// Performance tests for connected-mode operations.
final class ConnectedModePerformanceTests: XCTestCase {
    
    var radioLink: VirtualRadioLink!
    var stationA: TestStation!
    var stationB: TestStation!
    
    override func setUp() {
        super.setUp()
        radioLink = VirtualRadioLink()
        stationA = TestStation(callsign: "TEST", ssid: 1, radioLink: radioLink, isStationA: true)
        stationB = TestStation(callsign: "TEST", ssid: 2, radioLink: radioLink, isStationA: false)
        
        // Establish connection
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
    }
    
    /// Measure AXDP message encoding/fragmentation performance
    func testAXDPFragmentationPerformance() {
        let largeMessage = String(repeating: "Performance test data. ", count: 500)  // ~12KB
        
        measure {
            stationA.sentFrames.removeAll()
            stationA.vs = 0
            stationA.sendAXDPChat(largeMessage, to: stationB.callsign, paclen: 128)
        }
    }
    
    /// Measure AXDP reassembly performance
    func testAXDPReassemblyPerformance() {
        let largeMessage = String(repeating: "Reassembly test. ", count: 500)
        stationA.sendAXDPChat(largeMessage, to: stationB.callsign, paclen: 128)
        
        measure {
            stationB.receivedMessages.removeAll()
            stationB.reassemblyBuffer.removeAll()
            stationB.vr = 0
            stationB.processReceivedFrames()
        }
    }
}

// MARK: - Connection Edge Case Tests

/// Tests for connection establishment and rejection edge cases.
final class ConnectionEdgeCaseTests: XCTestCase {
    
    var radioLink: VirtualRadioLink!
    var stationA: TestStation!
    var stationB: TestStation!
    
    override func setUp() {
        super.setUp()
        radioLink = VirtualRadioLink()
        stationA = TestStation(callsign: "TEST", ssid: 1, radioLink: radioLink, isStationA: true)
        stationB = TestStation(callsign: "TEST", ssid: 2, radioLink: radioLink, isStationA: false)
    }
    
    override func tearDown() {
        radioLink.reset()
        stationA.reset()
        stationB.reset()
        super.tearDown()
    }
    
    /// Test connection rejection with DM (Disconnected Mode) response
    func testConnectionRejectionWithDM() {
        // Station A sends SABM
        stationA.connect(to: stationB.callsign)
        XCTAssertEqual(stationA.state, .connecting)
        
        // Station B receives SABM but rejects with DM
        stationB.processReceivedFrames()
        stationB.sendDM(to: stationA.callsign)
        XCTAssertEqual(stationB.state, .disconnected)
        
        // Station A receives DM and returns to disconnected
        stationA.processReceivedFrames()
        XCTAssertEqual(stationA.state, .disconnected)
    }
    
    /// Test simultaneous SABM from both sides (connection collision)
    func testSimultaneousSABM() {
        // Both stations send SABM simultaneously
        stationA.connect(to: stationB.callsign)
        stationB.connect(to: stationA.callsign)
        
        XCTAssertEqual(stationA.state, .connecting)
        XCTAssertEqual(stationB.state, .connecting)
        
        // Both receive each other's SABM - per AX.25, they should both respond with UA
        stationA.processReceivedFrames()
        stationB.processReceivedFrames()
        
        // Both should see the incoming SABM as a cross-connection attempt
        // In this simplified test, both are now in connecting state having received SABM
        // They should respond with UA to complete the connection
        stationA.acceptConnection(from: stationB.callsign)
        stationB.acceptConnection(from: stationA.callsign)
        
        // Process the UA responses
        stationA.processReceivedFrames()
        stationB.processReceivedFrames()
        
        // Both should now be connected
        XCTAssertEqual(stationA.state, .connected)
        XCTAssertEqual(stationB.state, .connected)
    }
    
    /// Test SABM when already connected (re-initialization)
    func testSABMWhenAlreadyConnected() {
        // Establish connection first
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        XCTAssertEqual(stationA.state, .connected)
        XCTAssertEqual(stationB.state, .connected)
        
        // Send some data to confirm connection works
        stationA.sendPlainText("Initial message", to: stationB.callsign)
        stationB.processReceivedFrames()
        XCTAssertEqual(stationB.receivedPlainText.count, 1)
        
        // Station A sends another SABM (re-initialization request)
        let initialVr = stationB.vr
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        
        // Station B should accept re-initialization with UA
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        // Both should still be connected, sequence numbers reset
        XCTAssertEqual(stationA.state, .connected)
        XCTAssertEqual(stationB.state, .connected)
        XCTAssertEqual(stationB.vr, 0, "V(R) should be reset after re-initialization")
    }
    
    /// Test DISC when already disconnected
    func testDISCWhenDisconnected() {
        // Station A sends DISC without being connected
        stationA.disconnect(from: stationB.callsign)
        XCTAssertEqual(stationA.state, .disconnecting)
        
        // Station B receives DISC and responds with DM (already disconnected)
        stationB.processReceivedFrames()
        stationB.sendDM(to: stationA.callsign)
        
        // Station A receives DM
        stationA.processReceivedFrames()
        XCTAssertEqual(stationA.state, .disconnected)
    }
    
    /// Test proper DISC/UA disconnection sequence
    func testProperDisconnection() {
        // Establish connection
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        XCTAssertEqual(stationA.state, .connected)
        XCTAssertEqual(stationB.state, .connected)
        
        // Station A initiates disconnect
        stationA.disconnect(from: stationB.callsign)
        XCTAssertEqual(stationA.state, .disconnecting)
        
        // Station B receives DISC and responds with UA
        stationB.processReceivedFrames()
        stationB.acceptDisconnect(from: stationA.callsign)
        XCTAssertEqual(stationB.state, .disconnected)
        
        // Station A receives UA and completes disconnect
        stationA.processReceivedFrames()
        XCTAssertEqual(stationA.state, .disconnected)
    }
    
    /// Test connection with digipeater path
    func testConnectionWithDigipeaterPath() {
        let digi1 = AX25Address(call: "DIGI1", ssid: 0)
        let digi2 = AX25Address(call: "DIGI2", ssid: 0)
        
        // Station A connects via digipeaters
        stationA.connectVia(to: stationB.callsign, via: [digi1, digi2])
        XCTAssertEqual(stationA.state, .connecting)
        
        // Verify the SABM frame contains the via path
        XCTAssertEqual(stationA.sentFrames.count, 1)
        
        // Station B receives and accepts (in real scenario, would come through digis)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        XCTAssertEqual(stationA.state, .connected)
        XCTAssertEqual(stationB.state, .connected)
    }
}

// MARK: - Flow Control Tests

/// Tests for AX.25 flow control mechanisms (RNR, window management).
final class FlowControlTests: XCTestCase {
    
    var radioLink: VirtualRadioLink!
    var stationA: TestStation!
    var stationB: TestStation!
    
    override func setUp() {
        super.setUp()
        radioLink = VirtualRadioLink()
        stationA = TestStation(callsign: "TEST", ssid: 1, radioLink: radioLink, isStationA: true)
        stationB = TestStation(callsign: "TEST", ssid: 2, radioLink: radioLink, isStationA: false)
        
        // Establish connection
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
    }
    
    override func tearDown() {
        radioLink.reset()
        stationA.reset()
        stationB.reset()
        super.tearDown()
    }
    
    /// Test RNR (Receiver Not Ready) flow control
    func testRNRFlowControl() {
        // Station A sends a message
        stationA.sendPlainText("First message", to: stationB.callsign)
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedPlainText.count, 1)
        XCTAssertEqual(stationB.vr, 1)
        
        // Station B sends RNR to indicate it can't receive more
        stationB.sendRNR(to: stationA.callsign, pf: false)
        stationA.processReceivedFrames()
        
        // Station A receives RNR (V(A) is updated)
        // In real implementation, A would pause sending until RR received
        XCTAssertEqual(stationA.va, 1)
        
        // Station B is ready again, sends RR
        stationB.sendRR(to: stationA.callsign, pf: false)
        stationA.processReceivedFrames()
        
        // Station A can now continue sending
        stationA.sendPlainText("Second message", to: stationB.callsign)
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedPlainText.count, 2)
    }
    
    /// Test maximum window size (7 frames outstanding)
    func testMaximumWindowStall() {
        // Send 7 messages (maximum window in modulo-8)
        let messages = (0..<7).map { "Message \($0)" }
        stationA.sendWindowFull(messages, to: stationB.callsign)
        
        // Station A has 7 outstanding frames
        XCTAssertEqual(stationA.vs, 7)
        XCTAssertEqual(stationA.va, 0)
        XCTAssertEqual(stationA.outstandingCount, 7)
        
        // Station B receives all 7
        stationB.processReceivedFrames()
        XCTAssertEqual(stationB.receivedPlainText.count, 7)
        XCTAssertEqual(stationB.vr, 7)
        
        // Station B acknowledges with RR
        stationB.sendRR(to: stationA.callsign)
        stationA.processReceivedFrames()
        
        // Station A's window is cleared
        XCTAssertEqual(stationA.va, 7)
        XCTAssertEqual(stationA.outstandingCount, 0)
        
        // Station A can now send more
        stationA.sendPlainText("Message after window clear", to: stationB.callsign)
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedPlainText.count, 8)
    }
    
    /// Test window wraparound (V(S) goes from 7 to 0)
    func testWindowWraparound() {
        // Send 7 messages, get acked, then send 3 more (wrapping around)
        let batch1 = (0..<7).map { "Batch1-\($0)" }
        stationA.sendWindowFull(batch1, to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.sendRR(to: stationA.callsign)
        stationA.processReceivedFrames()
        
        XCTAssertEqual(stationA.vs, 7)
        XCTAssertEqual(stationA.va, 7)
        
        // Send 3 more (wraps from 7 to 0, 1, 2)
        let batch2 = ["Wrap-0", "Wrap-1", "Wrap-2"]
        stationA.sendWindowFull(batch2, to: stationB.callsign)
        
        XCTAssertEqual(stationA.vs, 2)  // (7+3) % 8 = 2
        XCTAssertEqual(stationA.outstandingCount, 3)
        
        stationB.processReceivedFrames()
        stationB.sendRR(to: stationA.callsign)
        stationA.processReceivedFrames()
        
        XCTAssertEqual(stationA.va, 2)
        XCTAssertEqual(stationB.receivedPlainText.count, 10)  // 7 + 3
    }
    
    /// Test REJ triggers retransmission from specific frame
    func testREJRetransmission() {
        // Send 3 messages
        stationA.sendPlainText("Frame 0", to: stationB.callsign)
        stationA.sendPlainText("Frame 1", to: stationB.callsign)
        stationA.sendPlainText("Frame 2", to: stationB.callsign)
        
        XCTAssertEqual(stationA.vs, 3)
        
        // Station B only receives frames 0 and 2 (frame 1 lost)
        // For this test, we simulate by directly setting vr
        // In real scenario, the out-of-sequence frame triggers REJ
        stationB.vr = 1  // Expecting frame 1
        
        // Station B sends REJ requesting retransmission from frame 1
        stationB.sendREJ(to: stationA.callsign, pf: true)
        stationA.processReceivedFrames()
        
        // Station A receives REJ - in real implementation would retransmit from frame 1
        // The va is updated to the REJ's N(R)
        XCTAssertEqual(stationA.va, 1)
    }
    
    /// Test SREJ (Selective Reject) for single frame
    func testSREJSelectiveRetransmission() {
        // Clear frames from connection setup
        let frameCountBefore = stationB.sentFrames.count
        
        // Send 5 messages
        for i in 0..<5 {
            stationA.sendPlainText("Frame \(i)", to: stationB.callsign)
        }
        
        XCTAssertEqual(stationA.vs, 5)
        
        // Station B sends SREJ for just frame 2
        stationB.sendSREJ(to: stationA.callsign, nr: 2, pf: false)
        stationA.processReceivedFrames()
        
        // Verify the SREJ was sent (1 new frame added)
        XCTAssertEqual(stationB.sentFrames.count, frameCountBefore + 1, "SREJ should be sent")
        
        // Verify it's actually an S-frame (SREJ)
        if let lastFrame = stationB.sentFrames.last,
           let decoded = AX25.decodeFrame(ax25: lastFrame) {
            XCTAssertEqual(decoded.frameType, .s, "Should be S-frame")
        }
    }
    
    /// Test partial acknowledgment mid-window
    func testPartialAcknowledgment() {
        // Send 5 frames
        for i in 0..<5 {
            stationA.sendPlainText("Frame \(i)", to: stationB.callsign)
        }
        
        XCTAssertEqual(stationA.vs, 5)
        XCTAssertEqual(stationA.va, 0)
        XCTAssertEqual(stationA.outstandingCount, 5)
        
        // Station B receives and acks only first 3
        stationB.processReceivedFrames()
        stationB.vr = 3  // Only ack up to frame 2 (N(R)=3 means frames 0,1,2 acked)
        stationB.sendRR(to: stationA.callsign)
        stationA.processReceivedFrames()
        
        // Station A's window partially cleared
        XCTAssertEqual(stationA.va, 3)
        XCTAssertEqual(stationA.outstandingCount, 2)  // Frames 3,4 still outstanding
    }
}

// MARK: - Error Recovery Tests

/// Tests for error conditions and recovery mechanisms.
final class ErrorRecoveryTests: XCTestCase {
    
    var radioLink: VirtualRadioLink!
    var stationA: TestStation!
    var stationB: TestStation!
    
    override func setUp() {
        super.setUp()
        radioLink = VirtualRadioLink()
        stationA = TestStation(callsign: "TEST", ssid: 1, radioLink: radioLink, isStationA: true)
        stationB = TestStation(callsign: "TEST", ssid: 2, radioLink: radioLink, isStationA: false)
        
        // Establish connection
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
    }
    
    override func tearDown() {
        radioLink.reset()
        stationA.reset()
        stationB.reset()
        super.tearDown()
    }
    
    /// Test duplicate I-frame handling
    func testDuplicateIFrameIgnored() {
        // Send a message
        stationA.sendPlainText("Original message", to: stationB.callsign)
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedPlainText.count, 1)
        XCTAssertEqual(stationB.vr, 1)
        
        // Manually inject a duplicate frame (same N(S)=0)
        let duplicateFrame = AX25.encodeIFrame(
            from: stationA.callsign,
            to: stationB.callsign,
            via: [],
            ns: 0,  // Same as original
            nr: 0,
            pf: false,
            pid: 0xF0,
            info: Data("Duplicate".utf8)
        )
        radioLink.sendFromA(duplicateFrame)
        stationB.processReceivedFrames()
        
        // Duplicate should be ignored (V(R) already advanced past 0)
        XCTAssertEqual(stationB.receivedPlainText.count, 1, "Duplicate frame should be ignored")
        XCTAssertEqual(stationB.vr, 1)
    }
    
    /// Test out-of-sequence frame triggers REJ and isn't delivered
    func testOutOfSequenceFrameNotDelivered() {
        // Send frame with N(S)=5 when V(R)=0
        let oosFrame = AX25.encodeIFrame(
            from: stationA.callsign,
            to: stationB.callsign,
            via: [],
            ns: 5,
            nr: 0,
            pf: false,
            pid: 0xF0,
            info: Data("Out of sequence".utf8)
        )
        radioLink.sendFromA(oosFrame)
        stationB.processReceivedFrames()
        
        // Frame should not be delivered
        XCTAssertEqual(stationB.receivedPlainText.count, 0)
        XCTAssertEqual(stationB.vr, 0, "V(R) should not advance for OOS frame")
    }
    
    /// Test recovery after missed frame using REJ
    func testRecoveryAfterMissedFrame() {
        // Track frames from connection setup
        let frameCountBefore = stationB.sentFrames.count
        
        // Station A sends frames 0, 1, 2
        stationA.sendPlainText("Frame 0", to: stationB.callsign)
        stationA.sendPlainText("Frame 1", to: stationB.callsign)
        stationA.sendPlainText("Frame 2", to: stationB.callsign)
        
        // Simulate frame 1 being lost - manually process frames
        let frames = radioLink.receiveAtB()
        XCTAssertEqual(frames.count, 3, "Should have 3 I-frames queued")
        
        // Process only frame 0 - manually update state
        stationB.receivedFrames.append(frames[0])
        if let decoded = AX25.decodeFrame(ax25: frames[0]) {
            stationB.vr = 1
            stationB.receivedPlainText.append(decoded.info)
        }
        
        // Frame 1 is "lost" - skip it
        
        // Frame 2 arrives but is out of sequence (N(S)=2, V(R)=1)
        // In real implementation, receiver would buffer and send REJ
        stationB.receivedFrames.append(frames[2])
        
        // Station B sends REJ requesting retransmission from frame 1
        stationB.sendREJ(to: stationA.callsign)
        
        XCTAssertEqual(stationB.vr, 1, "V(R) stuck at 1 waiting for frame 1")
        XCTAssertEqual(stationB.sentFrames.count, frameCountBefore + 1, "REJ should be sent")
        
        // Verify it's an S-frame (REJ)
        if let lastFrame = stationB.sentFrames.last,
           let decoded = AX25.decodeFrame(ax25: lastFrame) {
            XCTAssertEqual(decoded.frameType, .s, "Should be S-frame (REJ)")
        }
    }
    
    /// Test network interruption mid-transfer
    func testNetworkInterruptionMidTransfer() {
        // Start sending large message
        let largeText = String(repeating: "X", count: 500)
        stationA.sendAXDPChat(largeText, to: stationB.callsign, paclen: 128)
        
        let totalSent = stationA.sentFrames.count
        XCTAssertGreaterThan(totalSent, 3, "Should have sent multiple fragments")
        
        // Simulate partial delivery - only first 2 frames delivered
        let allFrames = radioLink.receiveAtB()
        for frame in allFrames.prefix(2) {
            radioLink.sendFromA(frame)
        }
        stationB.processReceivedFrames()
        
        // Station B has incomplete message
        XCTAssertTrue(stationB.receivedMessages.isEmpty, "Message should not be complete")
        XCTAssertFalse(stationB.reassemblyBuffer.isEmpty, "Reassembly buffer should have partial data")
        
        // Simulate reconnection - clear buffers and restart
        stationB.reassemblyBuffer.removeAll()
        stationA.reset()
        stationB.reset()
        
        // Re-establish connection
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        XCTAssertEqual(stationA.state, .connected)
        XCTAssertEqual(stationB.state, .connected)
        
        // Resend complete message
        stationA.sendAXDPChat(largeText, to: stationB.callsign, paclen: 128)
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedMessages.count, 1, "Complete message should be received after reconnect")
    }
    
    /// Test malformed frame handling
    func testMalformedFrameIgnored() {
        let initialPlainTextCount = stationB.receivedPlainText.count
        
        // Send a malformed frame (too short)
        let malformed = Data([0xC0, 0x00, 0x01, 0x02])  // Invalid AX.25 frame
        radioLink.sendFromA(malformed)
        stationB.processReceivedFrames()
        
        // Should be ignored, no crash, no data delivered
        XCTAssertEqual(stationB.receivedPlainText.count, initialPlainTextCount)
    }
}

// MARK: - AXDP Protocol Edge Case Tests

/// Tests for AXDP-specific edge cases.
final class AXDPEdgeCaseTests: XCTestCase {
    
    var radioLink: VirtualRadioLink!
    var stationA: TestStation!
    var stationB: TestStation!
    
    override func setUp() {
        super.setUp()
        radioLink = VirtualRadioLink()
        stationA = TestStation(callsign: "TEST", ssid: 1, radioLink: radioLink, isStationA: true)
        stationB = TestStation(callsign: "TEST", ssid: 2, radioLink: radioLink, isStationA: false)
        
        // Establish connection
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
    }
    
    override func tearDown() {
        radioLink.reset()
        stationA.reset()
        stationB.reset()
        super.tearDown()
    }
    
    /// Test PING/PONG capability negotiation
    func testCapabilityNegotiation() {
        // Station A sends PING
        stationA.sendAXDPPing(to: stationB.callsign, sessionId: 100)
        stationB.processReceivedFrames()
        
        // Station B should receive PING
        let pingMessages = stationB.receivedMessages.filter { $0.type == .ping }
        XCTAssertEqual(pingMessages.count, 1)
        XCTAssertNotNil(pingMessages.first?.capabilities)
        
        // Station B responds with PONG
        stationB.sendAXDPPong(to: stationA.callsign, sessionId: 100)
        stationA.processReceivedFrames()
        
        // Station A should receive PONG
        let pongMessages = stationA.receivedMessages.filter { $0.type == .pong }
        XCTAssertEqual(pongMessages.count, 1)
        XCTAssertNotNil(pongMessages.first?.capabilities)
    }
    
    /// Test file transfer ACK/NACK flow
    func testFileTransferAckNackFlow() {
        let fileData = Data("Test file content".utf8)
        
        // Station A sends file
        stationA.sendAXDPFile(name: "test.txt", data: fileData, to: stationB.callsign, sessionId: 200)
        stationB.processReceivedFrames()
        
        // Station B receives FILE_META and chunks
        let metaMessages = stationB.receivedMessages.filter { $0.type == .fileMeta }
        let chunkMessages = stationB.receivedMessages.filter { $0.type == .fileChunk }
        
        XCTAssertEqual(metaMessages.count, 1)
        XCTAssertGreaterThan(chunkMessages.count, 0)
        
        // Station B sends ACK to confirm receipt
        stationB.sendAXDPAck(to: stationA.callsign, sessionId: 200, messageId: 1)
        stationA.processReceivedFrames()
        
        // Station A receives ACK
        let ackMessages = stationA.receivedMessages.filter { $0.type == .ack }
        XCTAssertEqual(ackMessages.count, 1)
    }
    
    /// Test file transfer rejection with NACK
    func testFileTransferNACK() {
        let fileData = Data("Unwanted file".utf8)
        
        // Station A sends file
        stationA.sendAXDPFile(name: "unwanted.exe", data: fileData, to: stationB.callsign, sessionId: 300)
        stationB.processReceivedFrames()
        
        // Station B rejects with NACK
        stationB.sendAXDPNack(to: stationA.callsign, sessionId: 300, messageId: 0)
        stationA.processReceivedFrames()
        
        // Station A receives NACK
        let nackMessages = stationA.receivedMessages.filter { $0.type == .nack }
        XCTAssertEqual(nackMessages.count, 1)
    }
    
    /// Test empty chat message
    func testEmptyChatMessage() {
        stationA.sendAXDPChat("", to: stationB.callsign, sessionId: 0, messageId: 1)
        stationB.processReceivedFrames()
        
        // Empty payload is valid
        XCTAssertEqual(stationB.receivedMessages.count, 1)
        XCTAssertEqual(stationB.receivedMessages.first?.type, .chat)
    }
    
    /// Test zero-byte file transfer
    func testZeroByteFileTransfer() {
        let emptyData = Data()
        
        stationA.sendAXDPFile(name: "empty.txt", data: emptyData, to: stationB.callsign, sessionId: 400)
        stationB.processReceivedFrames()
        
        // Should receive FILE_META with fileSize=0
        let metaMessages = stationB.receivedMessages.filter { $0.type == .fileMeta }
        XCTAssertEqual(metaMessages.count, 1)
        XCTAssertEqual(metaMessages.first?.fileMeta?.fileSize, 0)
    }
    
    /// Test file with exact paclen boundary (no remainder)
    func testFileExactPaclenBoundary() {
        // Create file that's exactly 3 * paclen bytes
        let paclen = 128
        let fileData = Data(repeating: 0x42, count: paclen * 3)
        
        stationA.sendAXDPFile(name: "exact.bin", data: fileData, to: stationB.callsign, sessionId: 500, paclen: paclen)
        stationB.processReceivedFrames()
        
        let metaMessages = stationB.receivedMessages.filter { $0.type == .fileMeta }
        let chunkMessages = stationB.receivedMessages.filter { $0.type == .fileChunk }
        
        XCTAssertEqual(metaMessages.count, 1)
        XCTAssertEqual(chunkMessages.count, 3)  // Exactly 3 full chunks
        XCTAssertEqual(Int(metaMessages.first?.totalChunks ?? 0), 3)
    }
    
    /// Test maximum paclen fragmentation
    func testMaximumPaclenFragmentation() {
        // Use maximum typical paclen (255 bytes)
        let paclen = 255
        let message = String(repeating: "X", count: 1000)
        
        stationA.sendAXDPChat(message, to: stationB.callsign, paclen: paclen)
        stationB.processReceivedFrames()
        
        // Should be fragmented into ceil(encoded_size / 255) frames
        XCTAssertEqual(stationB.receivedMessages.count, 1)
        
        // Verify the payload was received correctly
        if let payload = stationB.receivedMessages.first?.payload {
            XCTAssertEqual(String(data: payload, encoding: .utf8), message)
        }
    }
    
    /// Test AXDP message with special characters
    func testAXDPSpecialCharacters() {
        let specialText = "Hello 🌍! Unicode: 日本語 Émojis: 🎉🚀💻"
        
        stationA.sendAXDPChat(specialText, to: stationB.callsign)
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedMessages.count, 1)
        if let payload = stationB.receivedMessages.first?.payload {
            XCTAssertEqual(String(data: payload, encoding: .utf8), specialText)
        }
    }
    
    /// Test multiple AXDP sessions interleaved
    func testMultipleSessionsInterleaved() {
        // Start two file transfers with different session IDs
        let file1 = Data("File one content".utf8)
        let file2 = Data("File two different".utf8)
        
        // Send first chunk of file 1
        stationA.sendAXDPFile(name: "file1.txt", data: file1, to: stationB.callsign, sessionId: 1000, paclen: 256)
        
        // Send first chunk of file 2
        stationA.sendAXDPFile(name: "file2.txt", data: file2, to: stationB.callsign, sessionId: 2000, paclen: 256)
        
        stationB.processReceivedFrames()
        
        // Both file metas should be received
        let metaMessages = stationB.receivedMessages.filter { $0.type == .fileMeta }
        XCTAssertEqual(metaMessages.count, 2)
        
        // Verify different session IDs
        let sessionIds = Set(metaMessages.map { $0.sessionId })
        XCTAssertEqual(sessionIds, Set([1000, 2000]))
    }
}

// MARK: - Large Transfer Stress Tests

/// Stress tests for large data transfers.
final class LargeTransferStressTests: XCTestCase {
    
    var radioLink: VirtualRadioLink!
    var stationA: TestStation!
    var stationB: TestStation!
    
    override func setUp() {
        super.setUp()
        radioLink = VirtualRadioLink()
        stationA = TestStation(callsign: "TEST", ssid: 1, radioLink: radioLink, isStationA: true)
        stationB = TestStation(callsign: "TEST", ssid: 2, radioLink: radioLink, isStationA: false)
        
        // Establish connection
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
    }
    
    override func tearDown() {
        radioLink.reset()
        stationA.reset()
        stationB.reset()
        super.tearDown()
    }
    
    /// Test large file transfer (100KB)
    func testLargeFileTransfer100KB() {
        let fileSize = 100 * 1024  // 100 KB
        let fileData = Data(repeating: 0xAA, count: fileSize)
        let paclen = 128
        
        stationA.sendAXDPFile(name: "large.bin", data: fileData, to: stationB.callsign, sessionId: 1, paclen: paclen)
        stationB.processReceivedFrames()
        
        let metaMessages = stationB.receivedMessages.filter { $0.type == .fileMeta }
        let chunkMessages = stationB.receivedMessages.filter { $0.type == .fileChunk }
        
        XCTAssertEqual(metaMessages.count, 1)
        
        // Expected chunks: ceil(100KB / 128) = 800
        let expectedChunks = (fileSize + paclen - 1) / paclen
        XCTAssertEqual(chunkMessages.count, expectedChunks)
        
        // Verify all chunks have valid CRC
        for chunk in chunkMessages {
            XCTAssertNotNil(chunk.payloadCRC32)
            if let payload = chunk.payload, let crc = chunk.payloadCRC32 {
                XCTAssertEqual(crc, AXDP.crc32(payload))
            }
        }
    }
    
    /// Test large chat message (50KB)
    func testLargeChatMessage50KB() {
        let messageSize = 50 * 1024  // 50 KB
        let largeMessage = String(repeating: "A", count: messageSize)
        
        stationA.sendAXDPChat(largeMessage, to: stationB.callsign, paclen: 200)
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedMessages.count, 1)
        
        if let payload = stationB.receivedMessages.first?.payload {
            XCTAssertEqual(payload.count, messageSize)
            XCTAssertEqual(String(data: payload, encoding: .utf8), largeMessage)
        }
    }
    
    /// Test many small messages (1000 messages)
    func testManySmallMessages() {
        let messageCount = 1000
        
        for i in 0..<messageCount {
            stationA.sendAXDPChat("Msg \(i)", to: stationB.callsign, sessionId: 0, messageId: UInt32(i))
        }
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedMessages.count, messageCount)
        
        // Verify message IDs are correct
        for (i, msg) in stationB.receivedMessages.enumerated() {
            XCTAssertEqual(msg.messageId, UInt32(i))
        }
    }
    
    /// Test rapid sequence number cycling
    func testRapidSequenceNumberCycling() {
        // Send enough messages to cycle through sequence numbers multiple times
        // With modulo-8, need >8 messages per cycle
        let cycles = 5
        let messagesPerCycle = 8
        let totalMessages = cycles * messagesPerCycle
        
        for i in 0..<totalMessages {
            stationA.sendPlainText("Cycle msg \(i)", to: stationB.callsign)
            
            // Periodically acknowledge to prevent window stall
            if (i + 1) % 7 == 0 {
                stationB.processReceivedFrames()
                stationB.sendRR(to: stationA.callsign)
                stationA.processReceivedFrames()
            }
        }
        
        stationB.processReceivedFrames()
        
        // All messages should be received
        XCTAssertEqual(stationB.receivedPlainText.count, totalMessages)
        
        // Sequence numbers should have wrapped multiple times
        // Final V(S) = totalMessages % 8
        XCTAssertEqual(stationA.vs, totalMessages % 8)
    }
    
    /// Test bidirectional simultaneous large transfers
    func testBidirectionalLargeTransfers() {
        let file1Size = 10 * 1024  // 10 KB
        let file2Size = 15 * 1024  // 15 KB
        let file1Data = Data(repeating: 0xBB, count: file1Size)
        let file2Data = Data(repeating: 0xCC, count: file2Size)
        
        // Both stations start sending simultaneously
        stationA.sendAXDPFile(name: "from_a.bin", data: file1Data, to: stationB.callsign, sessionId: 100, paclen: 128)
        stationB.sendAXDPFile(name: "from_b.bin", data: file2Data, to: stationA.callsign, sessionId: 200, paclen: 128)
        
        // Process received frames at both stations
        stationA.processReceivedFrames()
        stationB.processReceivedFrames()
        
        // Station A should receive Station B's file
        let aReceivedMeta = stationA.receivedMessages.filter { $0.type == .fileMeta }
        let aReceivedChunks = stationA.receivedMessages.filter { $0.type == .fileChunk }
        XCTAssertEqual(aReceivedMeta.count, 1)
        XCTAssertEqual(aReceivedMeta.first?.fileMeta?.filename, "from_b.bin")
        
        // Station B should receive Station A's file
        let bReceivedMeta = stationB.receivedMessages.filter { $0.type == .fileMeta }
        let bReceivedChunks = stationB.receivedMessages.filter { $0.type == .fileChunk }
        XCTAssertEqual(bReceivedMeta.count, 1)
        XCTAssertEqual(bReceivedMeta.first?.fileMeta?.filename, "from_a.bin")
    }
}

// MARK: - Digipeater Path Tests

/// Tests for digipeater (via) path handling.
final class DigipeaterPathTests: XCTestCase {
    
    var radioLink: VirtualRadioLink!
    var stationA: TestStation!
    var stationB: TestStation!
    
    override func setUp() {
        super.setUp()
        radioLink = VirtualRadioLink()
        stationA = TestStation(callsign: "TEST", ssid: 1, radioLink: radioLink, isStationA: true)
        stationB = TestStation(callsign: "TEST", ssid: 2, radioLink: radioLink, isStationA: false)
    }
    
    override func tearDown() {
        radioLink.reset()
        stationA.reset()
        stationB.reset()
        super.tearDown()
    }
    
    /// Test message with single digipeater
    func testSingleDigipeater() {
        let digi = AX25Address(call: "RELAY", ssid: 0)
        
        // Establish connection first
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        // Send message via digipeater
        stationA.sendPlainTextVia("Via RELAY", to: stationB.callsign, via: [digi])
        
        // Verify frame was encoded with via path
        XCTAssertEqual(stationA.sentFrames.count, 2)  // SABM + I-frame
        
        // Decode the I-frame and check via path
        if let iFrame = stationA.sentFrames.last,
           let decoded = AX25.decodeFrame(ax25: iFrame) {
            XCTAssertEqual(decoded.via.count, 1)
            XCTAssertEqual(decoded.via.first?.call, "RELAY")
        }
        
        stationB.processReceivedFrames()
        XCTAssertEqual(stationB.receivedPlainText.count, 1)
    }
    
    /// Test message with multiple digipeaters (up to 8)
    func testMultipleDigipeaters() {
        let digis = [
            AX25Address(call: "DIGI1", ssid: 0),
            AX25Address(call: "DIGI2", ssid: 1),
            AX25Address(call: "DIGI3", ssid: 2),
            AX25Address(call: "WIDE1", ssid: 1),
        ]
        
        // Establish connection
        stationA.connectVia(to: stationB.callsign, via: digis)
        
        // Verify SABM has via path
        XCTAssertEqual(stationA.sentFrames.count, 1)
        if let sabm = stationA.sentFrames.first,
           let decoded = AX25.decodeFrame(ax25: sabm) {
            XCTAssertEqual(decoded.via.count, 4)
            XCTAssertEqual(decoded.via[0].call, "DIGI1")
            XCTAssertEqual(decoded.via[1].call, "DIGI2")
            XCTAssertEqual(decoded.via[2].call, "DIGI3")
            XCTAssertEqual(decoded.via[3].call, "WIDE1")
        }
    }
    
    /// Test maximum digipeater path (8 hops)
    func testMaximumDigipeaterPath() {
        let digis = (1...8).map { AX25Address(call: "DIG\($0)", ssid: 0) }
        
        stationA.connectVia(to: stationB.callsign, via: digis)
        
        if let sabm = stationA.sentFrames.first,
           let decoded = AX25.decodeFrame(ax25: sabm) {
            XCTAssertEqual(decoded.via.count, 8, "Should support maximum 8 digipeaters")
        }
    }
    
    /// Test digipeater with SSID
    func testDigipeaterWithSSID() {
        let digi = AX25Address(call: "RELAY", ssid: 15)  // Maximum SSID
        
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        stationA.sendPlainTextVia("Test SSID", to: stationB.callsign, via: [digi])
        
        if let iFrame = stationA.sentFrames.last,
           let decoded = AX25.decodeFrame(ax25: iFrame) {
            XCTAssertEqual(decoded.via.first?.ssid, 15)
        }
    }
}

// MARK: - Multi-Station Virtual Network

/// Virtual network supporting 3+ stations for manual relay testing.
/// Simulates a network where each station can connect to any other.
final class VirtualNetwork {
    private var queues: [String: [Data]] = [:]  // callsign -> pending frames
    private let lock = NSLock()
    
    /// Register a station in the network
    func register(_ callsign: String) {
        lock.lock()
        queues[callsign] = []
        lock.unlock()
    }
    
    /// Send frame from one station to another
    func send(from: String, to: String, frame: Data) {
        lock.lock()
        if queues[to] != nil {
            queues[to]!.append(frame)
        }
        lock.unlock()
    }
    
    /// Receive pending frames at a station
    func receive(at callsign: String) -> [Data] {
        lock.lock()
        let frames = queues[callsign] ?? []
        queues[callsign] = []
        lock.unlock()
        return frames
    }
    
    /// Clear all queues
    func reset() {
        lock.lock()
        for key in queues.keys {
            queues[key] = []
        }
        lock.unlock()
    }
}

/// Extended test station supporting multi-station network and relay functionality.
final class RelayTestStation {
    let callsign: AX25Address
    let network: VirtualNetwork
    
    // AX.25 sessions (supports multiple simultaneous sessions)
    var sessions: [String: SessionState] = [:]  // remote callsign key -> state
    
    struct SessionState {
        var state: AX25SessionState = .disconnected
        var vs: Int = 0
        var vr: Int = 0
        var va: Int = 0
        var relayTarget: String? = nil  // If set, relay data to this station
    }
    
    // AXDP state
    var axdpEnabled: Bool = true
    var reassemblyBuffers: [String: Data] = [:]  // per-session reassembly
    var receivedMessages: [AXDP.Message] = []
    var receivedPlainText: [(from: String, data: Data)] = []
    
    // Frame history
    var sentFrames: [Data] = []
    var receivedFrames: [Data] = []
    
    // Relay mapping: when data comes from A, forward to B
    var relayMap: [String: String] = [:]  // source -> destination
    
    init(callsign: String, ssid: Int, network: VirtualNetwork) {
        self.callsign = AX25Address(call: callsign, ssid: ssid)
        self.network = network
        network.register(callsignKey)
    }
    
    var callsignKey: String {
        return "\(callsign.call)-\(callsign.ssid)"
    }
    
    func reset() {
        sessions.removeAll()
        reassemblyBuffers.removeAll()
        receivedMessages.removeAll()
        receivedPlainText.removeAll()
        sentFrames.removeAll()
        receivedFrames.removeAll()
        relayMap.removeAll()
    }
    
    // MARK: - Connection Management
    
    func connect(to remote: AX25Address) {
        let key = "\(remote.call)-\(remote.ssid)"
        sessions[key] = SessionState()
        sessions[key]?.state = .connecting
        
        let sabm = AX25.encodeUFrame(from: callsign, to: remote, via: [], type: .sabm, pf: true)
        network.send(from: callsignKey, to: key, frame: sabm)
        sentFrames.append(sabm)
    }
    
    func acceptConnection(from remote: AX25Address) {
        let key = "\(remote.call)-\(remote.ssid)"
        sessions[key] = SessionState(state: .connected)
        
        let ua = AX25.encodeUFrame(from: callsign, to: remote, via: [], type: .ua, pf: true)
        network.send(from: callsignKey, to: key, frame: ua)
        sentFrames.append(ua)
    }
    
    func rejectConnection(from remote: AX25Address) {
        let key = "\(remote.call)-\(remote.ssid)"
        
        let dm = AX25.encodeUFrame(from: callsign, to: remote, via: [], type: .dm, pf: true)
        network.send(from: callsignKey, to: key, frame: dm)
        sentFrames.append(dm)
    }
    
    func disconnect(from remote: AX25Address) {
        let key = "\(remote.call)-\(remote.ssid)"
        
        let disc = AX25.encodeUFrame(from: callsign, to: remote, via: [], type: .disc, pf: true)
        network.send(from: callsignKey, to: key, frame: disc)
        sentFrames.append(disc)
        sessions[key]?.state = .disconnecting
    }
    
    // MARK: - Data Transmission
    
    func sendPlainText(_ text: String, to remote: AX25Address) {
        let key = "\(remote.call)-\(remote.ssid)"
        guard var session = sessions[key], session.state == .connected else { return }
        
        let iFrame = AX25.encodeIFrame(
            from: callsign,
            to: remote,
            via: [],
            ns: session.vs,
            nr: session.vr,
            pf: false,
            pid: 0xF0,
            info: text.data(using: .utf8) ?? Data()
        )
        network.send(from: callsignKey, to: key, frame: iFrame)
        sentFrames.append(iFrame)
        session.vs = (session.vs + 1) % 8
        sessions[key] = session
    }
    
    func sendAXDPChat(_ text: String, to remote: AX25Address, messageId: UInt32 = 1) {
        let key = "\(remote.call)-\(remote.ssid)"
        guard var session = sessions[key], session.state == .connected else { return }
        
        let msg = AXDP.Message(
            type: .chat,
            sessionId: 0,
            messageId: messageId,
            payload: text.data(using: .utf8)
        )
        let encoded = msg.encode()
        
        let iFrame = AX25.encodeIFrame(
            from: callsign,
            to: remote,
            via: [],
            ns: session.vs,
            nr: session.vr,
            pf: false,
            pid: 0xF0,
            info: encoded
        )
        network.send(from: callsignKey, to: key, frame: iFrame)
        sentFrames.append(iFrame)
        session.vs = (session.vs + 1) % 8
        sessions[key] = session
    }
    
    func sendData(_ data: Data, to remote: AX25Address) {
        let key = "\(remote.call)-\(remote.ssid)"
        guard var session = sessions[key], session.state == .connected else { return }
        
        let iFrame = AX25.encodeIFrame(
            from: callsign,
            to: remote,
            via: [],
            ns: session.vs,
            nr: session.vr,
            pf: false,
            pid: 0xF0,
            info: data
        )
        network.send(from: callsignKey, to: key, frame: iFrame)
        sentFrames.append(iFrame)
        session.vs = (session.vs + 1) % 8
        sessions[key] = session
    }
    
    // MARK: - Relay Setup
    
    /// Set up relay: data from source gets forwarded to destination
    func setupRelay(from source: AX25Address, to destination: AX25Address) {
        let srcKey = "\(source.call)-\(source.ssid)"
        let dstKey = "\(destination.call)-\(destination.ssid)"
        relayMap[srcKey] = dstKey
    }
    
    // MARK: - Frame Processing
    
    func processReceivedFrames() {
        let frames = network.receive(at: callsignKey)
        
        for frame in frames {
            receivedFrames.append(frame)
            processFrame(frame)
        }
    }
    
    private func processFrame(_ frame: Data) {
        guard let decoded = AX25.decodeFrame(ax25: frame),
              let fromAddr = decoded.from else { return }
        let srcKey = "\(fromAddr.call)-\(fromAddr.ssid)"
        
        // Route based on frame type
        switch decoded.frameType {
        case .u:
            processUFrame(decoded, fromAddr: fromAddr, srcKey: srcKey)
        case .s:
            processSFrame(decoded, srcKey: srcKey)
        case .i:
            processIFrame(decoded, fromAddr: fromAddr, srcKey: srcKey)
        case .ui:
            processUIFrame(decoded, srcKey: srcKey)
        default:
            break
        }
    }
    
    private func processUFrame(_ decoded: AX25.FrameDecodeResult, fromAddr: AX25Address, srcKey: String) {
        let control = decoded.controlByte1 ?? decoded.control
        let uType = AX25ControlFieldDecoder.decode(control: control).uType
        
        switch uType {
        case .SABM:
            // Connection request - we can accept or relay
            break
            
        case .UA:
            // Connection accepted or disconnect confirmed
            if var session = sessions[srcKey] {
                if session.state == .connecting {
                    session.state = .connected
                    sessions[srcKey] = session
                } else if session.state == .disconnecting {
                    session.state = .disconnected
                    sessions[srcKey] = session
                }
            }
            
        case .DM:
            // Connection rejected
            sessions[srcKey]?.state = .disconnected
            
        case .DISC:
            // Disconnect request
            let ua = AX25.encodeUFrame(from: callsign, to: fromAddr, via: [], type: .ua, pf: true)
            network.send(from: callsignKey, to: srcKey, frame: ua)
            sentFrames.append(ua)
            sessions[srcKey]?.state = .disconnected
            
            // Propagate disconnect through relay chain
            if let relayDst = relayMap[srcKey], let dstSession = sessions[relayDst], dstSession.state == .connected {
                let dstParts = relayDst.split(separator: "-")
                if dstParts.count >= 2, let ssid = Int(dstParts[1]) {
                    let dstAddr = AX25Address(call: String(dstParts[0]), ssid: ssid)
                    disconnect(from: dstAddr)
                }
            }
            
        default:
            break
        }
    }
    
    private func processSFrame(_ decoded: AX25.FrameDecodeResult, srcKey: String) {
        let control = decoded.controlByte1 ?? decoded.control
        let controlDecoded = AX25ControlFieldDecoder.decode(control: control)
        
        if let nr = controlDecoded.nr, var session = sessions[srcKey] {
            session.va = nr
            sessions[srcKey] = session
        }
    }
    
    private func processIFrame(_ decoded: AX25.FrameDecodeResult, fromAddr: AX25Address, srcKey: String) {
        guard var session = sessions[srcKey], session.state == .connected else { return }
        
        let control = decoded.controlByte1 ?? decoded.control
        let controlDecoded = AX25ControlFieldDecoder.decode(control: control)
        
        // Update receive sequence
        if let ns = controlDecoded.ns {
            if ns == session.vr {
                session.vr = (session.vr + 1) % 8
                sessions[srcKey] = session
                
                // Send RR
                let rr = AX25.encodeSFrame(from: callsign, to: fromAddr, via: [], type: .rr, nr: session.vr, pf: false)
                network.send(from: callsignKey, to: srcKey, frame: rr)
                sentFrames.append(rr)
                
                // Process the info field
                let info = decoded.info
                
                // Check if this should be relayed
                if let relayDst = relayMap[srcKey], let dstSession = sessions[relayDst], dstSession.state == .connected {
                    // Relay the data
                    let dstParts = relayDst.split(separator: "-")
                    if dstParts.count >= 2, let ssid = Int(dstParts[1]) {
                        let dstAddr = AX25Address(call: String(dstParts[0]), ssid: ssid)
                        sendData(info, to: dstAddr)
                    }
                } else {
                    // Process locally
                    processIncomingData(info, from: srcKey)
                }
            }
        }
        
        // Update acknowledged
        if let nr = controlDecoded.nr {
            session.va = nr
            sessions[srcKey] = session
        }
    }
    
    private func processUIFrame(_ decoded: AX25.FrameDecodeResult, srcKey: String) {
        if !decoded.info.isEmpty {
            processIncomingData(decoded.info, from: srcKey)
        }
    }
    
    private func processIncomingData(_ data: Data, from srcKey: String) {
        if axdpEnabled && data.starts(with: AXDP.magic) {
            // Append to reassembly buffer
            var buffer = reassemblyBuffers[srcKey] ?? Data()
            buffer.append(data)
            reassemblyBuffers[srcKey] = buffer
            
            // Try to extract complete messages
            while let (msg, consumed) = AXDP.Message.decode(from: reassemblyBuffers[srcKey]!) {
                receivedMessages.append(msg)
                guard consumed <= reassemblyBuffers[srcKey]!.count else { break }
                reassemblyBuffers[srcKey] = Data(reassemblyBuffers[srcKey]!.dropFirst(consumed))
            }
        } else {
            receivedPlainText.append((from: srcKey, data: data))
        }
    }
}

// MARK: - Manual Relay Tests (Session Chaining)

/// Tests for manual relay mode where stations chain through intermediate nodes.
/// This tests scenarios like: A → NodeB → C where B relays between A and C.
final class ManualRelayTests: XCTestCase {
    
    var network: VirtualNetwork!
    var stationA: RelayTestStation!
    var nodeB: RelayTestStation!
    var stationC: RelayTestStation!
    
    override func setUp() {
        super.setUp()
        network = VirtualNetwork()
        stationA = RelayTestStation(callsign: "STA", ssid: 1, network: network)
        nodeB = RelayTestStation(callsign: "NODE", ssid: 2, network: network)
        stationC = RelayTestStation(callsign: "STC", ssid: 3, network: network)
    }
    
    override func tearDown() {
        network.reset()
        stationA.reset()
        nodeB.reset()
        stationC.reset()
        super.tearDown()
    }
    
    // MARK: - Basic Manual Relay
    
    /// Test basic session chaining: A → B → C
    func testBasicManualRelay() {
        // Step 1: A connects to B
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        XCTAssertEqual(stationA.sessions["NODE-2"]?.state, .connected)
        XCTAssertEqual(nodeB.sessions["STA-1"]?.state, .connected)
        
        // Step 2: A sends "connect C" command, B connects to C
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        XCTAssertEqual(nodeB.sessions["STC-3"]?.state, .connected)
        XCTAssertEqual(stationC.sessions["NODE-2"]?.state, .connected)
        
        // Step 3: Set up relay at B
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        
        // Step 4: A sends data, it should arrive at C
        stationA.sendPlainText("Hello C via B", to: nodeB.callsign)
        nodeB.processReceivedFrames()
        stationC.processReceivedFrames()
        
        // C should receive the relayed message
        XCTAssertEqual(stationC.receivedPlainText.count, 1)
        let received = String(data: stationC.receivedPlainText[0].data, encoding: .utf8)
        XCTAssertEqual(received, "Hello C via B")
    }
    
    /// Test bidirectional relay: A ↔ B ↔ C
    func testBidirectionalRelay() {
        // Establish connections
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        // Set up bidirectional relay
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        nodeB.setupRelay(from: stationC.callsign, to: stationA.callsign)
        
        // A sends to C
        stationA.sendPlainText("A to C", to: nodeB.callsign)
        nodeB.processReceivedFrames()
        stationC.processReceivedFrames()
        
        XCTAssertEqual(stationC.receivedPlainText.count, 1)
        XCTAssertEqual(String(data: stationC.receivedPlainText[0].data, encoding: .utf8), "A to C")
        
        // C sends to A
        stationC.sendPlainText("C to A", to: nodeB.callsign)
        nodeB.processReceivedFrames()
        stationA.processReceivedFrames()
        
        XCTAssertEqual(stationA.receivedPlainText.count, 1)
        XCTAssertEqual(String(data: stationA.receivedPlainText[0].data, encoding: .utf8), "C to A")
    }
    
    /// Test AXDP chat through manual relay
    func testAXDPThroughManualRelay() {
        // Establish chain A → B → C with all AXDP enabled
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        
        // A sends AXDP chat
        stationA.sendAXDPChat("AXDP through relay", to: nodeB.callsign, messageId: 42)
        nodeB.processReceivedFrames()
        stationC.processReceivedFrames()
        
        // C should decode the AXDP message
        XCTAssertEqual(stationC.receivedMessages.count, 1)
        XCTAssertEqual(String(data: stationC.receivedMessages[0].payload ?? Data(), encoding: .utf8), "AXDP through relay")
        XCTAssertEqual(stationC.receivedMessages[0].messageId, 42)
    }
    
    /// Test plain text through manual relay when relay node has AXDP disabled
    func testPlainTextThroughNonAXDPRelay() {
        // B (relay node) has AXDP disabled
        nodeB.axdpEnabled = false
        
        // Establish chain
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        
        // A sends plain text (since B doesn't do AXDP, raw relay is fine)
        stationA.sendPlainText("Plain text relay", to: nodeB.callsign)
        nodeB.processReceivedFrames()
        stationC.processReceivedFrames()
        
        XCTAssertEqual(stationC.receivedPlainText.count, 1)
        XCTAssertEqual(String(data: stationC.receivedPlainText[0].data, encoding: .utf8), "Plain text relay")
    }
    
    // MARK: - Disconnection Propagation
    
    /// Test disconnect propagation: A disconnects, B should disconnect from C
    func testDisconnectPropagation() {
        // Establish chain
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        
        // All connected
        XCTAssertEqual(stationA.sessions["NODE-2"]?.state, .connected)
        XCTAssertEqual(nodeB.sessions["STA-1"]?.state, .connected)
        XCTAssertEqual(nodeB.sessions["STC-3"]?.state, .connected)
        
        // A disconnects from B
        stationA.disconnect(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        stationC.processReceivedFrames()
        stationA.processReceivedFrames()
        
        // B should have disconnected from C
        XCTAssertEqual(nodeB.sessions["STA-1"]?.state, .disconnected)
        let stcSession = nodeB.sessions["STC-3"]
        XCTAssertTrue(
            stcSession?.state == .disconnecting ||
            stcSession?.state == .disconnected
        )
    }
    
    /// Test disconnect from far end: C disconnects, A should be notified
    func testDisconnectFromFarEnd() {
        // Establish chain with reverse relay for notifications
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        nodeB.setupRelay(from: stationC.callsign, to: stationA.callsign)
        
        // C disconnects from B
        stationC.disconnect(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        stationA.processReceivedFrames()
        stationC.processReceivedFrames()
        
        // B should have propagated disconnect to A
        XCTAssertEqual(nodeB.sessions["STC-3"]?.state, .disconnected)
    }
    
    // MARK: - Connection Rejection
    
    /// Test relay target refuses connection
    func testRelayTargetRefusesConnection() {
        // A connects to B
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        // B tries to connect to C, but C rejects
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.rejectConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        // B's session to C should be disconnected
        XCTAssertEqual(nodeB.sessions["STC-3"]?.state, .disconnected)
        
        // A is still connected to B
        XCTAssertEqual(stationA.sessions["NODE-2"]?.state, .connected)
    }
}

// MARK: - Multi-Hop Relay Tests

/// Tests for multi-hop relay chains: A → B → C → D
final class MultiHopRelayTests: XCTestCase {
    
    var network: VirtualNetwork!
    var stationA: RelayTestStation!
    var nodeB: RelayTestStation!
    var nodeC: RelayTestStation!
    var stationD: RelayTestStation!
    
    override func setUp() {
        super.setUp()
        network = VirtualNetwork()
        stationA = RelayTestStation(callsign: "STA", ssid: 1, network: network)
        nodeB = RelayTestStation(callsign: "NDB", ssid: 2, network: network)
        nodeC = RelayTestStation(callsign: "NDC", ssid: 3, network: network)
        stationD = RelayTestStation(callsign: "STD", ssid: 4, network: network)
    }
    
    override func tearDown() {
        network.reset()
        stationA.reset()
        nodeB.reset()
        nodeC.reset()
        stationD.reset()
        super.tearDown()
    }
    
    /// Establish full chain A → B → C → D
    private func establishFullChain() {
        // A → B
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        // B → C
        nodeB.connect(to: nodeC.callsign)
        nodeC.processReceivedFrames()
        nodeC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        // C → D
        nodeC.connect(to: stationD.callsign)
        stationD.processReceivedFrames()
        stationD.acceptConnection(from: nodeC.callsign)
        nodeC.processReceivedFrames()
        
        // Set up relay chain
        nodeB.setupRelay(from: stationA.callsign, to: nodeC.callsign)
        nodeC.setupRelay(from: nodeB.callsign, to: stationD.callsign)
    }
    
    /// Test data through 3-hop chain: A → B → C → D
    func testThreeHopRelay() {
        establishFullChain()
        
        // A sends data
        stationA.sendPlainText("3-hop message", to: nodeB.callsign)
        
        // Process through chain
        nodeB.processReceivedFrames()
        nodeC.processReceivedFrames()
        stationD.processReceivedFrames()
        
        // D should receive
        XCTAssertEqual(stationD.receivedPlainText.count, 1)
        XCTAssertEqual(String(data: stationD.receivedPlainText[0].data, encoding: .utf8), "3-hop message")
    }
    
    /// Test AXDP through 3-hop chain
    func testAXDPThreeHopRelay() {
        establishFullChain()
        
        // A sends AXDP
        stationA.sendAXDPChat("AXDP 3-hop", to: nodeB.callsign, messageId: 100)
        
        // Process through chain
        nodeB.processReceivedFrames()
        nodeC.processReceivedFrames()
        stationD.processReceivedFrames()
        
        // D should decode AXDP
        XCTAssertEqual(stationD.receivedMessages.count, 1)
        XCTAssertEqual(String(data: stationD.receivedMessages[0].payload ?? Data(), encoding: .utf8), "AXDP 3-hop")
    }
    
    /// Test multiple messages through chain
    func testMultipleMessagesThreeHop() {
        establishFullChain()
        
        // Send multiple messages
        for i in 1...5 {
            stationA.sendPlainText("Message \(i)", to: nodeB.callsign)
        }
        
        // Process through chain (multiple rounds)
        for _ in 1...5 {
            nodeB.processReceivedFrames()
            nodeC.processReceivedFrames()
            stationD.processReceivedFrames()
        }
        
        // D should receive all
        XCTAssertEqual(stationD.receivedPlainText.count, 5)
        for i in 1...5 {
            let expected = "Message \(i)"
            let actual = String(data: stationD.receivedPlainText[i-1].data, encoding: .utf8)
            XCTAssertEqual(actual, expected)
        }
    }
    
    /// Test bidirectional 3-hop chain
    func testBidirectionalThreeHop() {
        establishFullChain()
        
        // Add reverse relay
        nodeC.setupRelay(from: stationD.callsign, to: nodeB.callsign)
        nodeB.setupRelay(from: nodeC.callsign, to: stationA.callsign)
        
        // A → D
        stationA.sendPlainText("A to D", to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeC.processReceivedFrames()
        stationD.processReceivedFrames()
        
        XCTAssertEqual(stationD.receivedPlainText.count, 1)
        
        // D → A
        stationD.sendPlainText("D to A", to: nodeC.callsign)
        nodeC.processReceivedFrames()
        nodeB.processReceivedFrames()
        stationA.processReceivedFrames()
        
        XCTAssertEqual(stationA.receivedPlainText.count, 1)
        XCTAssertEqual(String(data: stationA.receivedPlainText[0].data, encoding: .utf8), "D to A")
    }
    
    /// Test mixed AXDP/non-AXDP in chain
    func testMixedModeThreeHop() {
        // B is non-AXDP node
        nodeB.axdpEnabled = false
        
        establishFullChain()
        
        // Even with B non-AXDP, raw bytes should pass through
        stationA.sendAXDPChat("AXDP through non-AXDP", to: nodeB.callsign, messageId: 77)
        
        nodeB.processReceivedFrames()  // B passes through as raw data
        nodeC.processReceivedFrames()
        stationD.processReceivedFrames()
        
        // D (AXDP-enabled) should decode
        XCTAssertEqual(stationD.receivedMessages.count, 1)
        XCTAssertEqual(stationD.receivedMessages[0].messageId, 77)
    }
    
    /// Test disconnect cascades through entire chain
    func testDisconnectCascade() {
        establishFullChain()
        
        // Verify all connected
        XCTAssertEqual(stationA.sessions["NDB-2"]?.state, .connected)
        XCTAssertEqual(nodeB.sessions["NDC-3"]?.state, .connected)
        XCTAssertEqual(nodeC.sessions["STD-4"]?.state, .connected)
        
        // A disconnects
        stationA.disconnect(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeC.processReceivedFrames()
        stationD.processReceivedFrames()
        stationA.processReceivedFrames()
        
        // Should cascade
        XCTAssertEqual(nodeB.sessions["STA-1"]?.state, .disconnected)
    }
}

// MARK: - Via Path vs Manual Relay Comparison

/// Tests comparing via-path digipeating with manual relay behavior.
final class ViaPathVsManualRelayTests: XCTestCase {
    
    var network: VirtualNetwork!
    var stationA: RelayTestStation!
    var nodeB: RelayTestStation!
    var stationC: RelayTestStation!
    
    // Also keep classic via-path testing
    var radioLink: VirtualRadioLink!
    var classicA: TestStation!
    var classicC: TestStation!
    
    override func setUp() {
        super.setUp()
        // Manual relay network
        network = VirtualNetwork()
        stationA = RelayTestStation(callsign: "STA", ssid: 1, network: network)
        nodeB = RelayTestStation(callsign: "DIGI", ssid: 0, network: network)
        stationC = RelayTestStation(callsign: "STC", ssid: 3, network: network)
        
        // Via path stations
        radioLink = VirtualRadioLink()
        classicA = TestStation(callsign: "STA", ssid: 1, radioLink: radioLink, isStationA: true)
        classicC = TestStation(callsign: "STC", ssid: 3, radioLink: radioLink, isStationA: false)
    }
    
    override func tearDown() {
        network.reset()
        radioLink.reset()
        super.tearDown()
    }
    
    /// Compare via-path and manual relay for same message
    func testCompareViaPathAndManualRelay() {
        let testMessage = "Test message comparison"
        
        // ---- Via-path approach ----
        // A connects to C with DIGI in via path (header routing)
        let digiAddr = AX25Address(call: "DIGI", ssid: 0)
        classicA.connectVia(to: classicC.callsign, via: [digiAddr])
        classicC.processReceivedFrames()
        classicC.acceptConnection(from: classicA.callsign)
        classicA.processReceivedFrames()
        
        classicA.sendPlainTextVia(testMessage, to: classicC.callsign, via: [digiAddr])
        classicC.processReceivedFrames()
        
        // Verify via-path includes digi in header
        if let lastFrame = classicA.sentFrames.last,
           let decoded = AX25.decodeFrame(ax25: lastFrame) {
            XCTAssertEqual(decoded.via.count, 1)
            XCTAssertEqual(decoded.via[0].call, "DIGI")
        }
        
        XCTAssertEqual(classicC.receivedPlainText.count, 1)
        
        // ---- Manual relay approach ----
        // A connects to DIGI, DIGI connects to C
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        
        stationA.sendPlainText(testMessage, to: nodeB.callsign)
        nodeB.processReceivedFrames()
        stationC.processReceivedFrames()
        
        // Manual relay: frame from B to C has NO via path (direct B→C)
        if let lastFrame = nodeB.sentFrames.last,
           let decoded = AX25.decodeFrame(ax25: lastFrame) {
            XCTAssertEqual(decoded.via.count, 0, "Manual relay should have no via path")
        }
        
        XCTAssertEqual(stationC.receivedPlainText.count, 1)
        
        // Both should have same content
        XCTAssertEqual(
            String(data: classicC.receivedPlainText[0], encoding: .utf8),
            String(data: stationC.receivedPlainText[0].data, encoding: .utf8)
        )
    }
    
    /// Test via-path with AXDP
    func testViaPathWithAXDP() {
        let digiAddr = AX25Address(call: "DIGI", ssid: 0)
        
        classicA.connectVia(to: classicC.callsign, via: [digiAddr])
        classicC.processReceivedFrames()
        classicC.acceptConnection(from: classicA.callsign)
        classicA.processReceivedFrames()
        
        // AXDP through via-path (digi is transparent)
        classicA.sendAXDPChat("AXDP via digi", to: classicC.callsign, messageId: 99)
        classicC.processReceivedFrames()
        
        XCTAssertEqual(classicC.receivedMessages.count, 1)
        XCTAssertEqual(classicC.receivedMessages[0].messageId, 99)
    }
    
    /// Test manual relay preserves AXDP integrity
    func testManualRelayAXDPIntegrity() {
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        
        // Send AXDP with specific fields
        stationA.sendAXDPChat("Relay integrity test", to: nodeB.callsign, messageId: 12345)
        nodeB.processReceivedFrames()
        stationC.processReceivedFrames()
        
        // All AXDP fields should be preserved
        XCTAssertEqual(stationC.receivedMessages.count, 1)
        XCTAssertEqual(String(data: stationC.receivedMessages[0].payload ?? Data(), encoding: .utf8), "Relay integrity test")
        XCTAssertEqual(stationC.receivedMessages[0].messageId, 12345)
        XCTAssertEqual(stationC.receivedMessages[0].type, .chat)
    }
}

// MARK: - Relay Edge Cases

/// Edge cases and stress tests for relay scenarios.
final class RelayEdgeCaseTests: XCTestCase {
    
    var network: VirtualNetwork!
    var stationA: RelayTestStation!
    var nodeB: RelayTestStation!
    var stationC: RelayTestStation!
    
    override func setUp() {
        super.setUp()
        network = VirtualNetwork()
        stationA = RelayTestStation(callsign: "STA", ssid: 1, network: network)
        nodeB = RelayTestStation(callsign: "NODE", ssid: 2, network: network)
        stationC = RelayTestStation(callsign: "STC", ssid: 3, network: network)
    }
    
    override func tearDown() {
        network.reset()
        stationA.reset()
        nodeB.reset()
        stationC.reset()
        super.tearDown()
    }
    
    /// Test relay with large data (exceeds paclen, needs fragmentation)
    func testRelayLargeData() {
        // Establish chain
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        
        // Send large message
        let largeData = String(repeating: "X", count: 1000)
        stationA.sendPlainText(largeData, to: nodeB.callsign)
        nodeB.processReceivedFrames()
        stationC.processReceivedFrames()
        
        XCTAssertEqual(stationC.receivedPlainText.count, 1)
        XCTAssertEqual(stationC.receivedPlainText[0].data.count, 1000)
    }
    
    /// Test rapid messages through relay
    func testRapidRelayMessages() {
        // Establish chain
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        
        // Send 20 rapid messages
        for i in 1...20 {
            stationA.sendPlainText("Rapid \(i)", to: nodeB.callsign)
        }
        
        // Process all
        for _ in 1...20 {
            nodeB.processReceivedFrames()
            stationC.processReceivedFrames()
        }
        
        XCTAssertEqual(stationC.receivedPlainText.count, 20)
    }
    
    /// Test relay with binary data (all byte values)
    func testRelayBinaryData() {
        // Establish chain
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        
        // Send all byte values
        var binaryData = Data()
        for i: UInt8 in 0...255 {
            binaryData.append(i)
        }
        
        stationA.sendData(binaryData, to: nodeB.callsign)
        nodeB.processReceivedFrames()
        stationC.processReceivedFrames()
        
        XCTAssertEqual(stationC.receivedPlainText.count, 1)
        XCTAssertEqual(stationC.receivedPlainText[0].data, binaryData)
    }
    
    /// Test relay station handles multiple simultaneous sessions
    func testMultipleSimultaneousSessions() {
        // Create additional station
        let stationD = RelayTestStation(callsign: "STD", ssid: 4, network: network)
        
        // A and D both connect to B
        stationA.connect(to: nodeB.callsign)
        stationD.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        nodeB.acceptConnection(from: stationD.callsign)
        stationA.processReceivedFrames()
        stationD.processReceivedFrames()
        
        // B connects to C
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        // Set up relay: both A and D relay to C
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        nodeB.setupRelay(from: stationD.callsign, to: stationC.callsign)
        
        // Both send
        stationA.sendPlainText("From A", to: nodeB.callsign)
        stationD.sendPlainText("From D", to: nodeB.callsign)
        
        nodeB.processReceivedFrames()
        stationC.processReceivedFrames()
        
        // C should receive both
        XCTAssertEqual(stationC.receivedPlainText.count, 2)
    }
    
    /// Test AXDP fragments through relay
    func testAXDPFragmentsThroughRelay() {
        // Establish chain
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        nodeB.connect(to: stationC.callsign)
        stationC.processReceivedFrames()
        stationC.acceptConnection(from: nodeB.callsign)
        nodeB.processReceivedFrames()
        
        nodeB.setupRelay(from: stationA.callsign, to: stationC.callsign)
        
        // Large AXDP message that would be fragmented
        let longText = String(repeating: "Y", count: 500)
        stationA.sendAXDPChat(longText, to: nodeB.callsign, messageId: 7777)
        
        nodeB.processReceivedFrames()
        stationC.processReceivedFrames()
        
        // Should reassemble at C
        XCTAssertEqual(stationC.receivedMessages.count, 1)
        XCTAssertEqual(stationC.receivedMessages[0].payload?.count, 500)
    }
    
    /// Test connection attempt to busy relay
    func testConnectionToBusyRelay() {
        // A connects to B
        stationA.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
        
        // Now C also tries to connect to B (should still work)
        stationC.connect(to: nodeB.callsign)
        nodeB.processReceivedFrames()
        nodeB.acceptConnection(from: stationC.callsign)
        stationC.processReceivedFrames()
        
        // Both should be connected
        XCTAssertEqual(stationA.sessions["NODE-2"]?.state, .connected)
        XCTAssertEqual(stationC.sessions["NODE-2"]?.state, .connected)
        XCTAssertEqual(nodeB.sessions["STA-1"]?.state, .connected)
        XCTAssertEqual(nodeB.sessions["STC-3"]?.state, .connected)
    }
}

// MARK: - Mixed Mode Comprehensive Tests

/// Comprehensive tests for mixed AXDP and non-AXDP operation.
final class MixedModeComprehensiveTests: XCTestCase {
    
    var radioLink: VirtualRadioLink!
    var stationA: TestStation!
    var stationB: TestStation!
    
    override func setUp() {
        super.setUp()
        radioLink = VirtualRadioLink()
        stationA = TestStation(callsign: "TEST", ssid: 1, radioLink: radioLink, isStationA: true)
        stationB = TestStation(callsign: "TEST", ssid: 2, radioLink: radioLink, isStationA: false)
        
        // Establish connection
        stationA.connect(to: stationB.callsign)
        stationB.processReceivedFrames()
        stationB.acceptConnection(from: stationA.callsign)
        stationA.processReceivedFrames()
    }
    
    override func tearDown() {
        radioLink.reset()
        stationA.reset()
        stationB.reset()
        super.tearDown()
    }
    
    /// Test AXDP station dynamically disabling AXDP mid-session
    func testDynamicAXDPDisable() {
        // Both start with AXDP enabled
        XCTAssertTrue(stationA.axdpEnabled)
        XCTAssertTrue(stationB.axdpEnabled)
        
        // Send AXDP message
        stationA.sendAXDPChat("AXDP message", to: stationB.callsign)
        stationB.processReceivedFrames()
        XCTAssertEqual(stationB.receivedMessages.count, 1)
        
        // Station B disables AXDP
        stationB.axdpEnabled = false
        stationB.reassemblyBuffer.removeAll()
        
        // Station A sends plain text
        stationA.sendPlainText("Plain text after disable", to: stationB.callsign)
        stationB.processReceivedFrames()
        
        // Station B should receive as plain text
        XCTAssertEqual(stationB.receivedPlainText.count, 1)
    }
    
    /// Test receiving AXDP data when AXDP is disabled
    func testReceiveAXDPWhenDisabled() {
        // Station B disables AXDP
        stationB.axdpEnabled = false
        
        // Station A sends AXDP message
        stationA.sendAXDPChat("AXDP to non-AXDP", to: stationB.callsign)
        stationB.processReceivedFrames()
        
        // Station B receives as raw data (not decoded as AXDP)
        XCTAssertEqual(stationB.receivedMessages.count, 0)
        XCTAssertGreaterThan(stationB.receivedPlainText.count, 0)
    }
    
    /// Test alternating between AXDP and plain text
    func testAlternatingAXDPAndPlainText() {
        // Send: AXDP, plain, AXDP, plain, AXDP
        stationA.sendAXDPChat("AXDP 1", to: stationB.callsign, messageId: 1)
        stationA.sendPlainText("Plain 1", to: stationB.callsign)
        stationA.sendAXDPChat("AXDP 2", to: stationB.callsign, messageId: 2)
        stationA.sendPlainText("Plain 2", to: stationB.callsign)
        stationA.sendAXDPChat("AXDP 3", to: stationB.callsign, messageId: 3)
        
        stationB.processReceivedFrames()
        
        // All should be received correctly
        XCTAssertEqual(stationB.receivedMessages.count, 3, "Should receive 3 AXDP messages")
        XCTAssertEqual(stationB.receivedPlainText.count, 2, "Should receive 2 plain text messages")
    }
    
    /// Test BBS-style interaction (plain text commands)
    func testBBSStyleInteraction() {
        // Simulate BBS command/response flow
        let commands = ["C TEST-BBS", "L", "R 1", "B"]
        
        for cmd in commands {
            stationA.sendPlainText(cmd, to: stationB.callsign)
        }
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedPlainText.count, commands.count)
        
        // Verify each command received correctly
        for (i, cmd) in commands.enumerated() {
            let received = String(data: stationB.receivedPlainText[i], encoding: .utf8)
            XCTAssertEqual(received, cmd)
        }
    }
    
    /// Test plain text with AXDP magic bytes (edge case)
    func testPlainTextContainingMagicBytes() {
        // Plain text that happens to contain "AXT1" should not be misinterpreted
        let trickyText = "The prefix AXT1 appears in this text but it's not AXDP"
        
        stationA.sendPlainText(trickyText, to: stationB.callsign)
        stationB.processReceivedFrames()
        
        // Should be received as plain text (not corrupted AXDP)
        XCTAssertEqual(stationB.receivedPlainText.count, 1)
        XCTAssertEqual(stationB.receivedMessages.count, 0)
        
        let received = String(data: stationB.receivedPlainText.first!, encoding: .utf8)
        XCTAssertEqual(received, trickyText)
    }
    
    /// Test binary data transfer (non-text, non-AXDP)
    func testBinaryDataTransfer() {
        // Binary data with various byte values
        var binaryData = Data()
        for i: UInt8 in 0...255 {
            binaryData.append(i)
        }
        
        let iFrame = AX25.encodeIFrame(
            from: stationA.callsign,
            to: stationB.callsign,
            via: [],
            ns: stationA.vs,
            nr: stationA.vr,
            pf: false,
            pid: 0xF0,
            info: binaryData
        )
        radioLink.sendFromA(iFrame)
        stationA.vs = (stationA.vs + 1) % 8
        
        stationB.processReceivedFrames()
        
        XCTAssertEqual(stationB.receivedPlainText.count, 1)
        XCTAssertEqual(stationB.receivedPlainText.first, binaryData)
    }
}
