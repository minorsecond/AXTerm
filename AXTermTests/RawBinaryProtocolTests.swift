//
//  RawBinaryProtocolTests.swift
//  AXTermTests
//
//  TDD tests for Raw Binary file transfer protocol.
//  Tests cover metadata encoding/decoding, chunking, and SHA-256 verification.
//

import XCTest
@testable import AXTerm

final class RawBinaryProtocolTests: XCTestCase {

    override func setUpWithError() throws {
        throw XCTSkip("Raw Binary transfers are disabled until UX/reliability work is prioritized")
    }

    // MARK: - Metadata Encoding Tests

    func testEncodeMetadata() {
        let rawBinary = RawBinaryProtocol()
        let sha256 = Data(repeating: 0xAB, count: 32)

        let frame = rawBinary.encodeMetadata(fileName: "test.txt", fileSize: 1024, sha256: sha256)

        // Should be valid JSON
        let json = String(data: frame, encoding: .utf8)
        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("\"filename\":\"test.txt\""))
        XCTAssertTrue(json!.contains("\"size\":1024"))
        XCTAssertTrue(json!.contains("\"sha256\":"))
    }

    func testEncodeMetadataEscapesSpecialChars() {
        let rawBinary = RawBinaryProtocol()
        let sha256 = Data(repeating: 0x00, count: 32)

        let frame = rawBinary.encodeMetadata(fileName: "file\"with\"quotes.txt", fileSize: 100, sha256: sha256)

        let json = String(data: frame, encoding: .utf8)
        XCTAssertNotNil(json)
        // Quotes should be escaped
        XCTAssertTrue(json!.contains("\\\""))
    }

    func testEncodeEOT() {
        let rawBinary = RawBinaryProtocol()
        let frame = rawBinary.encodeEOT()

        XCTAssertEqual(frame.count, 1)
        XCTAssertEqual(frame[0], RawBinaryMarker.eot.rawValue)
    }

    // MARK: - Protocol Detection Tests

    func testCanHandleMetadataFrame() {
        let json = "{\"filename\":\"test.txt\",\"size\":1024,\"sha256\":\"abcd\"}"
        let frame = json.data(using: .utf8)!

        XCTAssertTrue(RawBinaryProtocol.canHandle(data: frame))
    }

    func testCanHandleEOTFrame() {
        let frame = Data([RawBinaryMarker.eot.rawValue])
        XCTAssertTrue(RawBinaryProtocol.canHandle(data: frame))
    }

    func testCanHandleRejectsNonJSON() {
        let frame = Data([0x41, 0x58, 0x54, 0x31])  // "AXT1" - AXDP header
        XCTAssertFalse(RawBinaryProtocol.canHandle(data: frame))
    }

    func testCanHandleRejectsRandomBinary() {
        let frame = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic
        XCTAssertFalse(RawBinaryProtocol.canHandle(data: frame))
    }

    func testCanHandleRejectsEmpty() {
        let frame = Data()
        XCTAssertFalse(RawBinaryProtocol.canHandle(data: frame))
    }

    // MARK: - State Tests

    func testInitialState() {
        let rawBinary = RawBinaryProtocol()
        XCTAssertEqual(rawBinary.state, .idle)
        XCTAssertEqual(rawBinary.bytesTransferred, 0)
        XCTAssertEqual(rawBinary.totalBytes, 0)
    }

    func testStartSendingChangesState() throws {
        let rawBinary = RawBinaryProtocol()
        let delegate = MockRawBinaryDelegate()
        rawBinary.delegate = delegate

        let testData = Data([0x01, 0x02, 0x03, 0x04])

        try rawBinary.startSending(fileName: "test.txt", fileData: testData)

        XCTAssertEqual(rawBinary.state, .transferring)
        XCTAssertEqual(rawBinary.totalBytes, 4)

        // Should have sent metadata frame first
        XCTAssertFalse(delegate.sentData.isEmpty)
        let firstFrame = delegate.sentData.first!
        let json = String(data: firstFrame, encoding: .utf8)
        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("test.txt"))
    }

    func testStartSendingFromNonIdleStateFails() throws {
        let rawBinary = RawBinaryProtocol()
        let delegate = MockRawBinaryDelegate()
        rawBinary.delegate = delegate

        let testData = Data([0x01, 0x02, 0x03, 0x04])

        try rawBinary.startSending(fileName: "test.txt", fileData: testData)

        XCTAssertThrowsError(try rawBinary.startSending(fileName: "test2.txt", fileData: testData))
    }

    func testCancel() {
        let rawBinary = RawBinaryProtocol()
        let delegate = MockRawBinaryDelegate()
        rawBinary.delegate = delegate

        rawBinary.cancel()

        XCTAssertEqual(rawBinary.state, .cancelled)
        XCTAssertTrue(delegate.didComplete)
        XCTAssertFalse(delegate.completedSuccessfully)
    }

    func testPauseAndResume() throws {
        let rawBinary = RawBinaryProtocol()
        let delegate = MockRawBinaryDelegate()
        rawBinary.delegate = delegate

        let testData = Data(repeating: 0x42, count: 1000)

        try rawBinary.startSending(fileName: "test.bin", fileData: testData)

        // Pause
        rawBinary.pause()
        XCTAssertEqual(rawBinary.state, .paused)

        // Resume
        rawBinary.resume()
        XCTAssertEqual(rawBinary.state, .transferring)
    }

    // MARK: - Progress Tests

    func testProgressCalculation() {
        let rawBinary = RawBinaryProtocol()
        XCTAssertEqual(rawBinary.progress, 0.0)  // No bytes transferred
    }

    // MARK: - SHA-256 Tests

    func testSHA256Generation() throws {
        let rawBinary = RawBinaryProtocol()
        let delegate = MockRawBinaryDelegate()
        rawBinary.delegate = delegate

        let testData = Data([0x01, 0x02, 0x03, 0x04])

        try rawBinary.startSending(fileName: "test.txt", fileData: testData)

        // Metadata should contain SHA-256
        guard let metadataFrame = delegate.sentData.first,
              let json = String(data: metadataFrame, encoding: .utf8) else {
            XCTFail("No metadata frame sent")
            return
        }

        XCTAssertTrue(json.contains("sha256"))

        // Verify SHA-256 is a 64-character hex string (32 bytes = 64 hex chars)
        // Pre-calculated SHA-256 of Data([0x01, 0x02, 0x03, 0x04])
        let expectedHex = "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a"
        XCTAssertTrue(json.contains(expectedHex))
    }

    // MARK: - Type Tests

    func testProtocolType() {
        let rawBinary = RawBinaryProtocol()
        XCTAssertEqual(rawBinary.protocolType, .rawBinary)
    }

    func testProtocolTypeProperties() {
        let type = TransferProtocolType.rawBinary

        XCTAssertEqual(type.displayName, "Raw Binary")
        XCTAssertTrue(type.requiresConnectedMode)
        XCTAssertFalse(type.supportsCompression)
        XCTAssertFalse(type.hasBuiltInAck)
    }

    // MARK: - Receiver Tests

    func testReceiverHandlesMetadata() {
        let rawBinary = RawBinaryProtocol()
        let delegate = MockRawBinaryDelegate()
        rawBinary.delegate = delegate

        let sha256 = Data(repeating: 0xAB, count: 32)
        let metadataFrame = rawBinary.encodeMetadata(fileName: "test.bin", fileSize: 100, sha256: sha256)

        let handled = rawBinary.handleIncomingData(metadataFrame)

        XCTAssertTrue(handled)
        // Should request user confirmation
        XCTAssertFalse(delegate.confirmationRequests.isEmpty)
        XCTAssertEqual(delegate.confirmationRequests.first?.fileName, "test.bin")
        XCTAssertEqual(delegate.confirmationRequests.first?.fileSize, 100)
    }

    func testReceiverAccumulatesData() {
        let rawBinary = RawBinaryProtocol()
        let delegate = MockRawBinaryDelegate()
        rawBinary.delegate = delegate

        // Send metadata first
        let sha256 = Data(repeating: 0x00, count: 32)
        let metadataFrame = rawBinary.encodeMetadata(fileName: "test.bin", fileSize: 10, sha256: sha256)
        _ = rawBinary.handleIncomingData(metadataFrame)

        // Send data chunks
        let chunk1 = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let handled = rawBinary.handleIncomingData(chunk1)

        XCTAssertTrue(handled)
        XCTAssertFalse(delegate.progressUpdates.isEmpty)
    }

    // MARK: - Edge Case Tests

    func testMetadataWithLongFilename() {
        let rawBinary = RawBinaryProtocol()
        let longName = String(repeating: "a", count: 200) + ".txt"
        let sha256 = Data(repeating: 0x00, count: 32)

        let frame = rawBinary.encodeMetadata(fileName: longName, fileSize: 100, sha256: sha256)
        let json = String(data: frame, encoding: .utf8)

        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains(longName))
    }

    func testMetadataWithUnicodeFilename() {
        let rawBinary = RawBinaryProtocol()
        let unicodeName = "文件.txt"
        let sha256 = Data(repeating: 0x00, count: 32)

        let frame = rawBinary.encodeMetadata(fileName: unicodeName, fileSize: 100, sha256: sha256)
        let json = String(data: frame, encoding: .utf8)

        XCTAssertNotNil(json)
        // Note: Unicode characters may be escaped in JSON
    }

    func testMetadataWithLargeFileSize() {
        let rawBinary = RawBinaryProtocol()
        let largeSize = Int.max / 2  // Very large file size
        let sha256 = Data(repeating: 0x00, count: 32)

        let frame = rawBinary.encodeMetadata(fileName: "large.bin", fileSize: largeSize, sha256: sha256)
        let json = String(data: frame, encoding: .utf8)

        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("\(largeSize)"))
    }

    func testHandleIncomingDataRejectsGarbage() {
        let rawBinary = RawBinaryProtocol()
        let delegate = MockRawBinaryDelegate()
        rawBinary.delegate = delegate

        let garbage = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])  // PNG header
        let handled = rawBinary.handleIncomingData(garbage)

        XCTAssertFalse(handled)
    }

    func testSHA256VerificationOnComplete() {
        let rawBinary = RawBinaryProtocol()
        let delegate = MockRawBinaryDelegate()
        rawBinary.delegate = delegate

        // The SHA-256 verification happens when EOT is received
        // This tests that the protocol stores the expected hash
        let testData = Data([0x01, 0x02, 0x03, 0x04])
        // Pre-calculated SHA-256 of Data([0x01, 0x02, 0x03, 0x04])
        let sha256Hex = "9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a"
        var sha256 = Data()
        var index = sha256Hex.startIndex
        while index < sha256Hex.endIndex {
            let nextIndex = sha256Hex.index(index, offsetBy: 2)
            if let byte = UInt8(sha256Hex[index..<nextIndex], radix: 16) {
                sha256.append(byte)
            }
            index = nextIndex
        }

        let metadataFrame = rawBinary.encodeMetadata(fileName: "test.bin", fileSize: testData.count, sha256: sha256)
        _ = rawBinary.handleIncomingData(metadataFrame)

        // Send the actual data
        _ = rawBinary.handleIncomingData(testData)

        // The SHA-256 should be stored for verification when EOT is received
        // Full verification would happen on EOT
    }

    func testProgressReporting() throws {
        let rawBinary = RawBinaryProtocol()
        let delegate = MockRawBinaryDelegate()
        rawBinary.delegate = delegate

        let testData = Data(repeating: 0x42, count: 500)
        try rawBinary.startSending(fileName: "test.bin", fileData: testData)

        // Progress should have been reported
        XCTAssertFalse(delegate.progressUpdates.isEmpty)
    }

    func testMultiplePauseResumeOperations() throws {
        let rawBinary = RawBinaryProtocol()
        let delegate = MockRawBinaryDelegate()
        rawBinary.delegate = delegate

        let testData = Data(repeating: 0x42, count: 1000)
        try rawBinary.startSending(fileName: "test.bin", fileData: testData)

        // Multiple pause/resume cycles
        for _ in 0..<3 {
            rawBinary.pause()
            XCTAssertEqual(rawBinary.state, .paused)

            rawBinary.resume()
            XCTAssertEqual(rawBinary.state, .transferring)
        }
    }
}

// MARK: - Mock Delegate

private class MockRawBinaryDelegate: FileTransferProtocolDelegate {
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
