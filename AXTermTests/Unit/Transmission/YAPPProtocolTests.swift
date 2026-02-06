//
//  YAPPProtocolTests.swift
//  AXTermTests
//
//  TDD tests for YAPP (Yet Another Packet Protocol) implementation.
//  Tests cover frame encoding/decoding, state machine transitions,
//  checksum calculation, and error handling.
//

import XCTest
@testable import AXTerm

final class YAPPProtocolTests: XCTestCase {

    // MARK: - Frame Encoding Tests

    func testEncodeSendInit() {
        let yapp = YAPPProtocol()
        let frame = yapp.encodeSendInit()

        XCTAssertEqual(frame.count, 2)
        XCTAssertEqual(frame[0], YAPPControlChar.soh.rawValue)
        XCTAssertEqual(frame[1], 0x01)
    }

    func testEncodeReceiveInit() {
        let yapp = YAPPProtocol()
        let frame = yapp.encodeReceiveInit()

        XCTAssertEqual(frame.count, 2)
        XCTAssertEqual(frame[0], YAPPControlChar.soh.rawValue)
        XCTAssertEqual(frame[1], 0x02)
    }

    func testEncodeHeader() {
        let yapp = YAPPProtocol()
        let frame = yapp.encodeHeader(fileName: "test.txt", fileSize: 1024)

        // Header format: [SOH, len, filename\0, size\0, timestamp\0]
        XCTAssertEqual(frame[0], YAPPControlChar.soh.rawValue)

        // Verify filename is present
        let frameString = String(data: frame.subdata(in: 2..<frame.count), encoding: .ascii)
        XCTAssertNotNil(frameString)
        XCTAssertTrue(frameString!.contains("test.txt"))
        XCTAssertTrue(frameString!.contains("1024"))
    }

    func testEncodeHeaderWithTimestamp() {
        let yapp = YAPPProtocol()
        let timestamp = Date(timeIntervalSince1970: 1700000000)
        let frame = yapp.encodeHeader(fileName: "test.txt", fileSize: 512, timestamp: timestamp)

        let frameString = String(data: frame.subdata(in: 2..<frame.count), encoding: .ascii)
        XCTAssertNotNil(frameString)
        XCTAssertTrue(frameString!.contains("1700000000"))
    }

    func testEncodeDataBlock() {
        let yapp = YAPPProtocol()
        let testData = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let frame = yapp.encodeDataBlock(data: testData)

        // Data format: [STX, len_hi, len_lo, data..., checksum]
        XCTAssertEqual(frame[0], YAPPControlChar.stx.rawValue)
        XCTAssertEqual(frame[1], 0x00)  // len_hi
        XCTAssertEqual(frame[2], 0x05)  // len_lo (5 bytes)

        // Verify data
        XCTAssertEqual(frame[3], 0x01)
        XCTAssertEqual(frame[4], 0x02)
        XCTAssertEqual(frame[5], 0x03)
        XCTAssertEqual(frame[6], 0x04)
        XCTAssertEqual(frame[7], 0x05)

        // Verify checksum (XOR of all data bytes)
        let expectedChecksum: UInt8 = 0x01 ^ 0x02 ^ 0x03 ^ 0x04 ^ 0x05
        XCTAssertEqual(frame[8], expectedChecksum)
    }

    func testEncodeEndFile() {
        let yapp = YAPPProtocol()
        let frame = yapp.encodeEndFile()

        XCTAssertEqual(frame.count, 2)
        XCTAssertEqual(frame[0], YAPPControlChar.etx.rawValue)
        XCTAssertEqual(frame[1], 0x01)
    }

    func testEncodeEndTransmission() {
        let yapp = YAPPProtocol()
        let frame = yapp.encodeEndTransmission()

        XCTAssertEqual(frame.count, 1)
        XCTAssertEqual(frame[0], YAPPControlChar.eot.rawValue)
    }

    func testEncodeAck() {
        let yapp = YAPPProtocol()
        let frame = yapp.encodeAck()

        XCTAssertEqual(frame.count, 1)
        XCTAssertEqual(frame[0], YAPPControlChar.ack.rawValue)
    }

    func testEncodeNak() {
        let yapp = YAPPProtocol()
        let frame = yapp.encodeNak()

        XCTAssertEqual(frame.count, 1)
        XCTAssertEqual(frame[0], YAPPControlChar.nak.rawValue)
    }

    func testEncodeCancel() {
        let yapp = YAPPProtocol()
        let frame = yapp.encodeCancel()

        XCTAssertEqual(frame.count, 1)
        XCTAssertEqual(frame[0], YAPPControlChar.can.rawValue)
    }

    // MARK: - Frame Parsing Tests

    func testParseFrameTypeSendInit() {
        let yapp = YAPPProtocol()
        let frame = Data([YAPPControlChar.soh.rawValue, 0x01])
        let frameType = yapp.parseFrameType(frame)

        XCTAssertEqual(frameType, .sendInit)
    }

    func testParseFrameTypeReceiveInit() {
        let yapp = YAPPProtocol()
        let frame = Data([YAPPControlChar.soh.rawValue, 0x02])
        let frameType = yapp.parseFrameType(frame)

        XCTAssertEqual(frameType, .receiveInit)
    }

    func testParseFrameTypeHeader() {
        let yapp = YAPPProtocol()
        let frame = Data([YAPPControlChar.soh.rawValue, 0x10, 0x74, 0x65, 0x73, 0x74])  // "test"
        let frameType = yapp.parseFrameType(frame)

        XCTAssertEqual(frameType, .header)
    }

    func testParseFrameTypeData() {
        let yapp = YAPPProtocol()
        let frame = Data([YAPPControlChar.stx.rawValue, 0x00, 0x05, 0x01, 0x02, 0x03, 0x04, 0x05, 0x05])
        let frameType = yapp.parseFrameType(frame)

        XCTAssertEqual(frameType, .data)
    }

    func testParseFrameTypeEndFile() {
        let yapp = YAPPProtocol()
        let frame = Data([YAPPControlChar.etx.rawValue, 0x01])
        let frameType = yapp.parseFrameType(frame)

        XCTAssertEqual(frameType, .endFile)
    }

    func testParseFrameTypeEndTransmission() {
        let yapp = YAPPProtocol()
        let frame = Data([YAPPControlChar.eot.rawValue])
        let frameType = yapp.parseFrameType(frame)

        XCTAssertEqual(frameType, .endTransmission)
    }

    func testParseFrameTypeAck() {
        let yapp = YAPPProtocol()
        let frame = Data([YAPPControlChar.ack.rawValue])
        let frameType = yapp.parseFrameType(frame)

        XCTAssertEqual(frameType, .ack)
    }

    func testParseFrameTypeNak() {
        let yapp = YAPPProtocol()
        let frame = Data([YAPPControlChar.nak.rawValue])
        let frameType = yapp.parseFrameType(frame)

        XCTAssertEqual(frameType, .nak)
    }

    func testParseFrameTypeCancel() {
        let yapp = YAPPProtocol()
        let frame = Data([YAPPControlChar.can.rawValue])
        let frameType = yapp.parseFrameType(frame)

        XCTAssertEqual(frameType, .cancel)
    }

    func testParseFrameTypeUnknown() {
        let yapp = YAPPProtocol()
        let frame = Data([0x99])  // Unknown control byte
        let frameType = yapp.parseFrameType(frame)

        XCTAssertEqual(frameType, .unknown)
    }

    func testParseFrameTypeEmptyData() {
        let yapp = YAPPProtocol()
        let frame = Data()
        let frameType = yapp.parseFrameType(frame)

        XCTAssertNil(frameType)
    }

    // MARK: - Header Parsing Tests

    func testParseHeader() {
        let yapp = YAPPProtocol()

        // Build a header: [SOH, len, "test.txt\0", "1024\0", "\0"]
        var frame = Data([YAPPControlChar.soh.rawValue])
        var payload = Data()
        payload.append("test.txt".data(using: .ascii)!)
        payload.append(0x00)
        payload.append("1024".data(using: .ascii)!)
        payload.append(0x00)
        payload.append(0x00)  // No timestamp

        frame.append(UInt8(payload.count))
        frame.append(payload)

        let result = yapp.parseHeader(frame)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.fileName, "test.txt")
        XCTAssertEqual(result?.fileSize, 1024)
        XCTAssertNil(result?.timestamp)
    }

    func testParseHeaderWithTimestamp() {
        let yapp = YAPPProtocol()

        var frame = Data([YAPPControlChar.soh.rawValue])
        var payload = Data()
        payload.append("data.bin".data(using: .ascii)!)
        payload.append(0x00)
        payload.append("512".data(using: .ascii)!)
        payload.append(0x00)
        payload.append("1700000000".data(using: .ascii)!)
        payload.append(0x00)

        frame.append(UInt8(payload.count))
        frame.append(payload)

        let result = yapp.parseHeader(frame)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.fileName, "data.bin")
        XCTAssertEqual(result?.fileSize, 512)
        XCTAssertNotNil(result?.timestamp)
        XCTAssertEqual(result?.timestamp?.timeIntervalSince1970, 1700000000)
    }

    func testParseHeaderInvalid() {
        let yapp = YAPPProtocol()

        // Invalid: wrong start byte
        let frame = Data([0x99, 0x05, 0x74, 0x65, 0x73, 0x74, 0x00])
        let result = yapp.parseHeader(frame)

        XCTAssertNil(result)
    }

    func testParseHeaderTruncated() {
        let yapp = YAPPProtocol()

        // Truncated: length says 20 but only 5 bytes follow
        let frame = Data([YAPPControlChar.soh.rawValue, 20, 0x74, 0x65, 0x73, 0x74, 0x00])
        let result = yapp.parseHeader(frame)

        XCTAssertNil(result)
    }

    // MARK: - Data Block Parsing Tests

    func testParseDataBlock() {
        let yapp = YAPPProtocol()

        // Build a data block: [STX, 0x00, 0x05, data..., checksum]
        let testData = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let checksum: UInt8 = 0x01 ^ 0x02 ^ 0x03 ^ 0x04 ^ 0x05

        var frame = Data([YAPPControlChar.stx.rawValue, 0x00, 0x05])
        frame.append(testData)
        frame.append(checksum)

        let result = yapp.parseDataBlock(frame)

        XCTAssertNotNil(result)
        XCTAssertEqual(result, testData)
    }

    func testParseDataBlockChecksumMismatch() {
        let yapp = YAPPProtocol()

        // Build a data block with wrong checksum
        let testData = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let wrongChecksum: UInt8 = 0xFF

        var frame = Data([YAPPControlChar.stx.rawValue, 0x00, 0x05])
        frame.append(testData)
        frame.append(wrongChecksum)

        let result = yapp.parseDataBlock(frame)

        XCTAssertNil(result)  // Should fail checksum verification
    }

    func testParseDataBlockTruncated() {
        let yapp = YAPPProtocol()

        // Truncated: length says 5 but only 3 bytes follow
        let frame = Data([YAPPControlChar.stx.rawValue, 0x00, 0x05, 0x01, 0x02, 0x03])
        let result = yapp.parseDataBlock(frame)

        XCTAssertNil(result)
    }

    func testParseDataBlockWrongStartByte() {
        let yapp = YAPPProtocol()

        let frame = Data([0x99, 0x00, 0x05, 0x01, 0x02, 0x03, 0x04, 0x05, 0x05])
        let result = yapp.parseDataBlock(frame)

        XCTAssertNil(result)
    }

    // MARK: - Checksum Tests

    func testCalculateChecksum() {
        let yapp = YAPPProtocol()

        let data1 = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertEqual(yapp.calculateChecksum(data1), 0x01 ^ 0x02 ^ 0x03 ^ 0x04 ^ 0x05)

        let data2 = Data([0xFF, 0xFF])
        XCTAssertEqual(yapp.calculateChecksum(data2), 0x00)  // XOR of same values is 0

        let data3 = Data([0xAA])
        XCTAssertEqual(yapp.calculateChecksum(data3), 0xAA)  // Single byte

        let data4 = Data()
        XCTAssertEqual(yapp.calculateChecksum(data4), 0x00)  // Empty data
    }

    // MARK: - Protocol Detection Tests

    func testCanHandleSendInit() {
        let frame = Data([YAPPControlChar.soh.rawValue, 0x01])
        XCTAssertTrue(YAPPProtocol.canHandle(data: frame))
    }

    func testCanHandleData() {
        let frame = Data([YAPPControlChar.stx.rawValue, 0x00, 0x05, 0x01, 0x02, 0x03, 0x04, 0x05, 0x05])
        XCTAssertTrue(YAPPProtocol.canHandle(data: frame))
    }

    func testCanHandleAck() {
        let frame = Data([YAPPControlChar.ack.rawValue])
        XCTAssertTrue(YAPPProtocol.canHandle(data: frame))
    }

    func testCanHandleNonYAPP() {
        let frame = Data([0x41, 0x58, 0x54, 0x31])  // "AXT1" - AXDP header
        XCTAssertFalse(YAPPProtocol.canHandle(data: frame))
    }

    func testCanHandleEmpty() {
        let frame = Data()
        XCTAssertFalse(YAPPProtocol.canHandle(data: frame))
    }

    // MARK: - State Machine Tests

    func testInitialState() {
        let yapp = YAPPProtocol()
        XCTAssertEqual(yapp.state, .idle)
    }

    func testStartSendingChangesState() throws {
        let yapp = YAPPProtocol()
        let delegate = MockYAPPDelegate()
        yapp.delegate = delegate

        let testData = Data([0x01, 0x02, 0x03, 0x04])

        try yapp.startSending(fileName: "test.txt", fileData: testData)

        XCTAssertEqual(yapp.state, .waitingForAccept)
        XCTAssertEqual(yapp.totalBytes, 4)
        XCTAssertEqual(yapp.bytesTransferred, 0)

        // Should have sent SI frame
        XCTAssertFalse(delegate.sentData.isEmpty)
        XCTAssertEqual(delegate.sentData.first?[0], YAPPControlChar.soh.rawValue)
        XCTAssertEqual(delegate.sentData.first?[1], 0x01)
    }

    func testStartSendingFromNonIdleStateFails() throws {
        let yapp = YAPPProtocol()
        let delegate = MockYAPPDelegate()
        yapp.delegate = delegate

        let testData = Data([0x01, 0x02, 0x03, 0x04])

        // First call should succeed
        try yapp.startSending(fileName: "test.txt", fileData: testData)

        // Second call should fail
        XCTAssertThrowsError(try yapp.startSending(fileName: "test2.txt", fileData: testData)) { error in
            XCTAssertTrue(error is FileTransferError)
        }
    }

    func testCancelChangesState() {
        let yapp = YAPPProtocol()
        let delegate = MockYAPPDelegate()
        yapp.delegate = delegate

        yapp.cancel()

        XCTAssertEqual(yapp.state, .cancelled)
        XCTAssertTrue(delegate.didComplete)
        XCTAssertFalse(delegate.completedSuccessfully)
    }

    // MARK: - Round-Trip Encoding/Decoding Tests

    func testDataBlockRoundTrip() {
        let yapp = YAPPProtocol()
        let originalData = Data((0..<256).map { UInt8($0) })

        let encoded = yapp.encodeDataBlock(data: originalData)
        let decoded = yapp.parseDataBlock(encoded)

        XCTAssertEqual(decoded, originalData)
    }

    func testHeaderRoundTrip() {
        let yapp = YAPPProtocol()
        let fileName = "test_file.bin"
        let fileSize = 123456

        let encoded = yapp.encodeHeader(fileName: fileName, fileSize: fileSize)
        let decoded = yapp.parseHeader(encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.fileName, fileName)
        XCTAssertEqual(decoded?.fileSize, fileSize)
    }

    // MARK: - Protocol Type Tests

    func testProtocolType() {
        let yapp = YAPPProtocol()
        XCTAssertEqual(yapp.protocolType, .yapp)
    }

    func testProtocolTypeProperties() {
        let type = TransferProtocolType.yapp

        XCTAssertEqual(type.displayName, "YAPP")
        XCTAssertTrue(type.requiresConnectedMode)
        XCTAssertFalse(type.supportsCompression)
        XCTAssertTrue(type.hasBuiltInAck)
    }

    // MARK: - Receiver State Machine Tests

    func testReceiverHandlesSendInit() {
        let yapp = YAPPProtocol()
        let delegate = MockYAPPDelegate()
        yapp.delegate = delegate

        // Receiver gets SI frame
        let siFrame = Data([YAPPControlChar.soh.rawValue, 0x01])
        let handled = yapp.handleIncomingData(siFrame)

        XCTAssertTrue(handled)
        // Should have sent RI (Receive Init) response
        XCTAssertFalse(delegate.sentData.isEmpty)
        XCTAssertEqual(delegate.sentData.first?[0], YAPPControlChar.soh.rawValue)
        XCTAssertEqual(delegate.sentData.first?[1], 0x02)  // RI indicator
    }

    func testReceiverHandlesHeader() {
        let yapp = YAPPProtocol()
        let delegate = MockYAPPDelegate()
        yapp.delegate = delegate

        // First send SI to get into receiving state
        let siFrame = Data([YAPPControlChar.soh.rawValue, 0x01])
        _ = yapp.handleIncomingData(siFrame)
        delegate.sentData.removeAll()

        // Now send header
        let header = yapp.encodeHeader(fileName: "test.txt", fileSize: 1024)
        let handled = yapp.handleIncomingData(header)

        XCTAssertTrue(handled)
        // Should request user confirmation
        XCTAssertFalse(delegate.confirmationRequests.isEmpty)
        XCTAssertEqual(delegate.confirmationRequests.first?.fileName, "test.txt")
        XCTAssertEqual(delegate.confirmationRequests.first?.fileSize, 1024)
    }

    func testReceiverAcceptsTransfer() {
        let yapp = YAPPProtocol()
        let delegate = MockYAPPDelegate()
        yapp.delegate = delegate

        // Setup: SI -> RI, Header -> confirmation request
        let siFrame = Data([YAPPControlChar.soh.rawValue, 0x01])
        _ = yapp.handleIncomingData(siFrame)
        let header = yapp.encodeHeader(fileName: "test.txt", fileSize: 100)
        _ = yapp.handleIncomingData(header)
        delegate.sentData.removeAll()

        // Accept the transfer
        yapp.acceptTransfer()

        // Should have sent ACK
        XCTAssertFalse(delegate.sentData.isEmpty)
        XCTAssertEqual(delegate.sentData.first, Data([YAPPControlChar.ack.rawValue]))
        XCTAssertEqual(yapp.state, .transferring)
    }

    func testReceiverRejectsTransfer() {
        let yapp = YAPPProtocol()
        let delegate = MockYAPPDelegate()
        yapp.delegate = delegate

        // Setup: SI -> RI, Header -> confirmation request
        let siFrame = Data([YAPPControlChar.soh.rawValue, 0x01])
        _ = yapp.handleIncomingData(siFrame)
        let header = yapp.encodeHeader(fileName: "test.txt", fileSize: 100)
        _ = yapp.handleIncomingData(header)
        delegate.sentData.removeAll()

        // Reject the transfer
        yapp.rejectTransfer(reason: "File too large")

        // Should have sent CAN
        XCTAssertFalse(delegate.sentData.isEmpty)
        XCTAssertEqual(delegate.sentData.first, Data([YAPPControlChar.can.rawValue]))
        XCTAssertEqual(yapp.state, .cancelled)
    }

    func testReceiverHandlesDataBlock() {
        let yapp = YAPPProtocol()
        let delegate = MockYAPPDelegate()
        yapp.delegate = delegate

        // Setup: complete handshake
        _ = yapp.handleIncomingData(Data([YAPPControlChar.soh.rawValue, 0x01]))
        _ = yapp.handleIncomingData(yapp.encodeHeader(fileName: "test.txt", fileSize: 100))
        yapp.acceptTransfer()
        delegate.sentData.removeAll()
        delegate.progressUpdates.removeAll()

        // Send a data block
        let testData = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let dataBlock = yapp.encodeDataBlock(data: testData)
        let handled = yapp.handleIncomingData(dataBlock)

        XCTAssertTrue(handled)
        // Should have sent ACK
        XCTAssertFalse(delegate.sentData.isEmpty)
        XCTAssertEqual(delegate.sentData.first, Data([YAPPControlChar.ack.rawValue]))
        // Should have progress update
        XCTAssertFalse(delegate.progressUpdates.isEmpty)
    }

    func testReceiverHandlesCorruptDataBlock() {
        let yapp = YAPPProtocol()
        let delegate = MockYAPPDelegate()
        yapp.delegate = delegate

        // Setup: complete handshake
        _ = yapp.handleIncomingData(Data([YAPPControlChar.soh.rawValue, 0x01]))
        _ = yapp.handleIncomingData(yapp.encodeHeader(fileName: "test.txt", fileSize: 100))
        yapp.acceptTransfer()
        delegate.sentData.removeAll()

        // Send corrupt data block (bad checksum)
        var dataBlock = yapp.encodeDataBlock(data: Data([0x01, 0x02, 0x03]))
        dataBlock[dataBlock.count - 1] = 0xFF  // Corrupt checksum
        let handled = yapp.handleIncomingData(dataBlock)

        XCTAssertTrue(handled)
        // Should have sent NAK
        XCTAssertFalse(delegate.sentData.isEmpty)
        XCTAssertEqual(delegate.sentData.first, Data([YAPPControlChar.nak.rawValue]))
    }

    func testReceiverHandlesCancel() {
        let yapp = YAPPProtocol()
        let delegate = MockYAPPDelegate()
        yapp.delegate = delegate

        // Start a transfer
        _ = yapp.handleIncomingData(Data([YAPPControlChar.soh.rawValue, 0x01]))
        _ = yapp.handleIncomingData(yapp.encodeHeader(fileName: "test.txt", fileSize: 100))
        yapp.acceptTransfer()

        // Sender cancels
        let cancelFrame = Data([YAPPControlChar.can.rawValue])
        let handled = yapp.handleIncomingData(cancelFrame)

        XCTAssertTrue(handled)
        XCTAssertEqual(yapp.state, .cancelled)
        XCTAssertTrue(delegate.didComplete)
        XCTAssertFalse(delegate.completedSuccessfully)
    }

    // MARK: - Full Transfer Simulation Tests

    func testFullTransferSmallFile() {
        let sender = YAPPProtocol()
        let receiver = YAPPProtocol()
        let senderDelegate = MockYAPPDelegate()
        let receiverDelegate = MockYAPPDelegate()
        sender.delegate = senderDelegate
        receiver.delegate = receiverDelegate

        let originalData = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        // Sender starts
        try? sender.startSending(fileName: "test.bin", fileData: originalData)

        // Simulate message exchange
        // Sender sent SI -> Receiver
        if let siFrame = senderDelegate.sentData.first {
            _ = receiver.handleIncomingData(siFrame)
        }

        // Receiver sent RI -> Sender (as ACK)
        if let riFrame = receiverDelegate.sentData.first {
            sender.handleAck(data: riFrame)
        }

        // Receiver gets header, accepts
        if senderDelegate.sentData.count > 1 {
            _ = receiver.handleIncomingData(senderDelegate.sentData[1])
        }
        receiver.acceptTransfer()

        // This tests the basic flow - a complete simulation would need
        // to handle all the data blocks and ACKs
        XCTAssertEqual(receiver.state, .transferring)
    }

    // MARK: - Edge Case Tests

    func testEmptyFileName() {
        let yapp = YAPPProtocol()
        let header = yapp.encodeHeader(fileName: "", fileSize: 100)
        let parsed = yapp.parseHeader(header)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.fileName, "")
        XCTAssertEqual(parsed?.fileSize, 100)
    }

    func testZeroSizeFile() {
        let yapp = YAPPProtocol()
        let header = yapp.encodeHeader(fileName: "empty.txt", fileSize: 0)
        let parsed = yapp.parseHeader(header)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.fileSize, 0)
    }

    func testLargeDataBlock() {
        let yapp = YAPPProtocol()
        let largeData = Data(repeating: 0xAB, count: 250)

        let encoded = yapp.encodeDataBlock(data: largeData)
        let decoded = yapp.parseDataBlock(encoded)

        XCTAssertEqual(decoded, largeData)
    }

    func testAllByteValuesChecksum() {
        let yapp = YAPPProtocol()
        let allBytes = Data((0...255).map { UInt8($0) })

        let encoded = yapp.encodeDataBlock(data: allBytes)
        let decoded = yapp.parseDataBlock(encoded)

        XCTAssertEqual(decoded, allBytes)
    }

    func testPauseAndResumePreservesState() throws {
        let yapp = YAPPProtocol()
        let delegate = MockYAPPDelegate()
        yapp.delegate = delegate

        let testData = Data(repeating: 0x42, count: 1000)
        try yapp.startSending(fileName: "test.bin", fileData: testData)

        let initialTotalBytes = yapp.totalBytes

        yapp.pause()
        XCTAssertEqual(yapp.state, .paused)
        XCTAssertEqual(yapp.totalBytes, initialTotalBytes)

        yapp.resume()
        XCTAssertNotEqual(yapp.state, .paused)
        XCTAssertEqual(yapp.totalBytes, initialTotalBytes)
    }

    func testProgressCalculation() throws {
        let yapp = YAPPProtocol()
        XCTAssertEqual(yapp.progress, 0.0)

        // When totalBytes is 0, progress should be 0
        XCTAssertEqual(yapp.totalBytes, 0)
        XCTAssertEqual(yapp.progress, 0.0)
    }

    func testSpecialCharactersInFilename() {
        let yapp = YAPPProtocol()
        let specialName = "file with spaces & symbols!.txt"
        let header = yapp.encodeHeader(fileName: specialName, fileSize: 100)
        let parsed = yapp.parseHeader(header)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.fileName, specialName)
    }
}

// MARK: - Mock Delegate

/// Mock delegate for testing protocol events
private class MockYAPPDelegate: FileTransferProtocolDelegate {
    var sentData: [Data] = []
    var progressUpdates: [(progress: Double, bytes: Int)] = []
    var stateChanges: [TransferProtocolState] = []
    var receivedFiles: [(data: Data, metadata: TransferFileMetadata)] = []
    var confirmationRequests: [TransferFileMetadata] = []

    var didComplete = false
    var completedSuccessfully = false
    var completionError: String?

    func transferProtocol(_ proto: FileTransferProtocol, needsToSend data: Data) {
        sentData.append(data)
    }

    func transferProtocol(_ proto: FileTransferProtocol, didUpdateProgress progress: Double, bytesSent: Int) {
        progressUpdates.append((progress, bytesSent))
    }

    func transferProtocol(_ proto: FileTransferProtocol, didComplete successfully: Bool, error: String?) {
        didComplete = true
        completedSuccessfully = successfully
        completionError = error
    }

    func transferProtocol(_ proto: FileTransferProtocol, didReceiveFile data: Data, metadata: TransferFileMetadata) {
        receivedFiles.append((data, metadata))
    }

    func transferProtocol(_ proto: FileTransferProtocol, requestsConfirmation metadata: TransferFileMetadata) {
        confirmationRequests.append(metadata)
    }

    func transferProtocol(_ proto: FileTransferProtocol, stateChanged newState: TransferProtocolState) {
        stateChanges.append(newState)
    }
}
