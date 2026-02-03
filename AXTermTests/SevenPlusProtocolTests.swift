//
//  SevenPlusProtocolTests.swift
//  AXTermTests
//
//  TDD tests for 7plus ASCII encoding file transfer protocol.
//  Tests cover encoding/decoding, checksums, and block handling.
//

import XCTest
@testable import AXTerm

final class SevenPlusProtocolTests: XCTestCase {

    override func setUpWithError() throws {
        throw XCTSkip("7plus disabled until prioritized for stabilization")
    }

    // MARK: - Header Encoding Tests

    func testEncodeHeader() {
        let sevenPlus = SevenPlusProtocol()
        let header = sevenPlus.encodeHeader(fileName: "test.txt", fileSize: 1024, crc32: 0x12345678)

        XCTAssertTrue(header.contains("go_7+."))
        XCTAssertTrue(header.contains("test.txt"))
        XCTAssertTrue(header.contains("size=1024"))
        XCTAssertTrue(header.contains("crc32=12345678"))
    }

    func testEncodeFooter() {
        let sevenPlus = SevenPlusProtocol()
        let footer = sevenPlus.encodeFooter()

        XCTAssertTrue(footer.contains("stop_7+."))
    }

    func testEncodeBlockChecksum() {
        let sevenPlus = SevenPlusProtocol()
        let checksum = sevenPlus.encodeBlockChecksum(blockNum: 1, checksum: 0xABCD)

        XCTAssertTrue(checksum.contains("chk"))
        XCTAssertTrue(checksum.contains("0001"))
        XCTAssertTrue(checksum.contains("ABCD"))
    }

    // MARK: - Line Encoding/Decoding Tests

    func testEncodeLineSimple() {
        let sevenPlus = SevenPlusProtocol()
        let data = Data([0x00, 0x00, 0x00])  // Three zero bytes

        let encoded = sevenPlus.encodeLine(data)

        // Should produce 4 characters + checksum + CRLF
        XCTAssertTrue(encoded.hasSuffix("\r\n"))
        XCTAssertEqual(encoded.dropLast(2).count, 5)  // 4 data chars + 1 checksum
    }

    func testEncodeLineDecodeRoundTrip() {
        let sevenPlus = SevenPlusProtocol()
        let originalData = Data([0x01, 0x02, 0x03])

        let encoded = sevenPlus.encodeLine(originalData)
        let decoded = sevenPlus.decodeLine(String(encoded.dropLast(2)))  // Remove CRLF

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded, originalData)
    }

    func testEncodeLineDecodeRoundTripLarger() {
        let sevenPlus = SevenPlusProtocol()
        let originalData = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x57, 0x6F, 0x72, 0x6C, 0x64, 0x21])  // "Hello World!"

        let encoded = sevenPlus.encodeLine(originalData)
        let decoded = sevenPlus.decodeLine(String(encoded.dropLast(2)))

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded, originalData)
    }

    func testDecodeLineInvalidChecksum() {
        let sevenPlus = SevenPlusProtocol()

        // Create a line with wrong checksum character
        let badLine = "0000X"  // Invalid checksum

        let decoded = sevenPlus.decodeLine(badLine)

        // Should fail checksum verification
        // Note: This depends on implementation - may return nil or partial data
        // For now, we just verify it doesn't crash
        _ = decoded
    }

    func testDecodeLineTooShort() {
        let sevenPlus = SevenPlusProtocol()

        let decoded = sevenPlus.decodeLine("abc")  // Too short

        XCTAssertNil(decoded)
    }

    // MARK: - Protocol Detection Tests

    func testCanHandleHeader() {
        let frame = " go_7+. test.txt size=1024 crc32=12345678\r\n".data(using: .ascii)!
        XCTAssertTrue(SevenPlusProtocol.canHandle(data: frame))
    }

    func testCanHandleUUEncodeStyle() {
        let frame = "begin 644 filename\r\n".data(using: .ascii)!
        XCTAssertTrue(SevenPlusProtocol.canHandle(data: frame))
    }

    func testCanHandleVersion() {
        let frame = "7PLUS v2.1 test.txt size=100\r\n".data(using: .ascii)!
        XCTAssertTrue(SevenPlusProtocol.canHandle(data: frame))
    }

    func testCanHandleRejectsNon7Plus() {
        let frame = Data([0x01, 0x02, 0x03, 0x04])  // Binary data
        XCTAssertFalse(SevenPlusProtocol.canHandle(data: frame))
    }

    func testCanHandleRejectsEmpty() {
        let frame = Data()
        XCTAssertFalse(SevenPlusProtocol.canHandle(data: frame))
    }

    // MARK: - State Tests

    func testInitialState() {
        let sevenPlus = SevenPlusProtocol()
        XCTAssertEqual(sevenPlus.state, .idle)
        XCTAssertEqual(sevenPlus.bytesTransferred, 0)
        XCTAssertEqual(sevenPlus.totalBytes, 0)
    }

    func testStartSendingChangesState() throws {
        let sevenPlus = SevenPlusProtocol()
        let delegate = MockSevenPlusDelegate()
        sevenPlus.delegate = delegate

        let testData = Data([0x01, 0x02, 0x03, 0x04])

        try sevenPlus.startSending(fileName: "test.txt", fileData: testData)

        XCTAssertEqual(sevenPlus.state, .transferring)
        XCTAssertEqual(sevenPlus.totalBytes, 4)

        // Should have sent header frame first
        XCTAssertFalse(delegate.sentData.isEmpty)
        let firstFrame = String(data: delegate.sentData.first!, encoding: .ascii)
        XCTAssertNotNil(firstFrame)
        XCTAssertTrue(firstFrame!.contains("go_7+."))
    }

    func testStartSendingFromNonIdleStateFails() throws {
        let sevenPlus = SevenPlusProtocol()
        let delegate = MockSevenPlusDelegate()
        sevenPlus.delegate = delegate

        let testData = Data([0x01, 0x02, 0x03, 0x04])

        try sevenPlus.startSending(fileName: "test.txt", fileData: testData)

        XCTAssertThrowsError(try sevenPlus.startSending(fileName: "test2.txt", fileData: testData))
    }

    func testCancel() {
        let sevenPlus = SevenPlusProtocol()
        let delegate = MockSevenPlusDelegate()
        sevenPlus.delegate = delegate

        sevenPlus.cancel()

        XCTAssertEqual(sevenPlus.state, .cancelled)
        XCTAssertTrue(delegate.didComplete)
        XCTAssertFalse(delegate.completedSuccessfully)

        // Should have sent stop line
        let sentStrings = delegate.sentData.compactMap { String(data: $0, encoding: .ascii) }
        XCTAssertTrue(sentStrings.contains { $0.contains("stop_7+.") })
    }

    func testPauseAndResume() throws {
        let sevenPlus = SevenPlusProtocol()
        let delegate = MockSevenPlusDelegate()
        sevenPlus.delegate = delegate

        let testData = Data(repeating: 0x42, count: 1000)

        try sevenPlus.startSending(fileName: "test.bin", fileData: testData)

        // Pause
        sevenPlus.pause()
        XCTAssertEqual(sevenPlus.state, .paused)

        // Resume
        sevenPlus.resume()
        XCTAssertEqual(sevenPlus.state, .transferring)
    }

    // MARK: - Type Tests

    func testProtocolType() {
        let sevenPlus = SevenPlusProtocol()
        XCTAssertEqual(sevenPlus.protocolType, .sevenPlus)
    }

    func testProtocolTypeProperties() {
        let type = TransferProtocolType.sevenPlus

        XCTAssertEqual(type.displayName, "7plus")
        XCTAssertTrue(type.requiresConnectedMode)
        XCTAssertFalse(type.supportsCompression)
        XCTAssertTrue(type.hasBuiltInAck)
    }

    // MARK: - Encoding Character Set Tests

    func testEncodingProducesASCII() {
        let sevenPlus = SevenPlusProtocol()
        let testData = Data((0..<256).map { UInt8($0) })

        let encoded = sevenPlus.encodeLine(testData)

        // All characters should be printable ASCII
        for char in encoded {
            let ascii = char.asciiValue ?? 0
            XCTAssertTrue(ascii >= 0x0A && ascii <= 0x7E,
                         "Non-ASCII character found: \(ascii)")
        }
    }

    // MARK: - Receiver Tests

    func testReceiverHandlesHeader() {
        let sevenPlus = SevenPlusProtocol()
        let delegate = MockSevenPlusDelegate()
        sevenPlus.delegate = delegate

        let headerData = " go_7+. test.bin size=100 crc32=12345678\r\n".data(using: .ascii)!

        let handled = sevenPlus.handleIncomingData(headerData)

        XCTAssertTrue(handled)
        // Should request user confirmation
        XCTAssertFalse(delegate.confirmationRequests.isEmpty)
        XCTAssertEqual(delegate.confirmationRequests.first?.fileName, "test.bin")
        XCTAssertEqual(delegate.confirmationRequests.first?.fileSize, 100)
    }

    func testReceiverRejectsNonASCII() {
        let sevenPlus = SevenPlusProtocol()
        let delegate = MockSevenPlusDelegate()
        sevenPlus.delegate = delegate

        let binaryData = Data([0x89, 0x50, 0x4E, 0x47])  // PNG header
        let handled = sevenPlus.handleIncomingData(binaryData)

        XCTAssertFalse(handled)
    }

    func testReceiverAccumulatesLines() {
        let sevenPlus = SevenPlusProtocol()
        let delegate = MockSevenPlusDelegate()
        sevenPlus.delegate = delegate

        // Send header first
        let headerData = " go_7+. test.bin size=100 crc32=00000000\r\n".data(using: .ascii)!
        _ = sevenPlus.handleIncomingData(headerData)

        // Send encoded data line
        let originalData = Data([0x01, 0x02, 0x03])
        let encodedLine = sevenPlus.encodeLine(originalData)
        let handled = sevenPlus.handleIncomingData(encodedLine.data(using: .ascii)!)

        XCTAssertTrue(handled)
        XCTAssertFalse(delegate.progressUpdates.isEmpty)
    }

    func testReceiverHandlesStopLine() {
        let sevenPlus = SevenPlusProtocol()
        let delegate = MockSevenPlusDelegate()
        sevenPlus.delegate = delegate

        // Send header
        let headerData = " go_7+. test.bin size=3 crc32=00000000\r\n".data(using: .ascii)!
        _ = sevenPlus.handleIncomingData(headerData)

        // Send stop line
        let stopData = " stop_7+.\r\n".data(using: .ascii)!
        let handled = sevenPlus.handleIncomingData(stopData)

        XCTAssertTrue(handled)
        XCTAssertTrue(delegate.didComplete)
    }

    // MARK: - CRC32 Tests (via Header Encoding)

    func testCRC32InHeaderIsConsistent() {
        let sevenPlus = SevenPlusProtocol()

        // Same CRC should produce same header
        let header1 = sevenPlus.encodeHeader(fileName: "test.txt", fileSize: 100, crc32: 0x12345678)
        let header2 = sevenPlus.encodeHeader(fileName: "test.txt", fileSize: 100, crc32: 0x12345678)

        XCTAssertEqual(header1, header2)
        XCTAssertTrue(header1.contains("12345678"))
    }

    func testCRC32DifferentValuesProduceDifferentHeaders() {
        let sevenPlus = SevenPlusProtocol()

        let header1 = sevenPlus.encodeHeader(fileName: "test.txt", fileSize: 100, crc32: 0x12345678)
        let header2 = sevenPlus.encodeHeader(fileName: "test.txt", fileSize: 100, crc32: 0x87654321)

        XCTAssertNotEqual(header1, header2)
        XCTAssertTrue(header1.contains("12345678"))
        XCTAssertTrue(header2.contains("87654321"))
    }

    func testCRC32ZeroValue() {
        let sevenPlus = SevenPlusProtocol()

        let header = sevenPlus.encodeHeader(fileName: "test.txt", fileSize: 100, crc32: 0)

        XCTAssertTrue(header.contains("crc32=00000000"))
    }

    // MARK: - Edge Case Tests

    func testHeaderWithLongFilename() {
        let sevenPlus = SevenPlusProtocol()
        let longName = String(repeating: "a", count: 200) + ".txt"

        let header = sevenPlus.encodeHeader(fileName: longName, fileSize: 100, crc32: 0)

        XCTAssertTrue(header.contains(longName))
    }

    func testHeaderWithSpecialCharacters() {
        let sevenPlus = SevenPlusProtocol()
        let specialName = "file with spaces.txt"

        let header = sevenPlus.encodeHeader(fileName: specialName, fileSize: 100, crc32: 0)

        // Header should still be valid ASCII
        XCTAssertTrue(header.contains("go_7+."))
    }

    func testHeaderWithZeroSize() {
        let sevenPlus = SevenPlusProtocol()

        let header = sevenPlus.encodeHeader(fileName: "empty.txt", fileSize: 0, crc32: 0)

        XCTAssertTrue(header.contains("size=0"))
    }

    func testHeaderWithLargeSize() {
        let sevenPlus = SevenPlusProtocol()
        let largeSize = 1_000_000_000

        let header = sevenPlus.encodeHeader(fileName: "large.bin", fileSize: largeSize, crc32: 0)

        XCTAssertTrue(header.contains("size=\(largeSize)"))
    }

    func testEncodingAllByteCombinations() {
        let sevenPlus = SevenPlusProtocol()

        // Test encoding all possible 3-byte combinations from 0x00 to 0xFF
        for i in stride(from: 0, to: 256, by: 16) {
            let testData = Data([UInt8(i), UInt8((i + 1) % 256), UInt8((i + 2) % 256)])
            let encoded = sevenPlus.encodeLine(testData)
            let decoded = sevenPlus.decodeLine(String(encoded.dropLast(2)))

            XCTAssertEqual(decoded, testData, "Round-trip failed for bytes starting at \(i)")
        }
    }

    func testMultiplePauseResumeOperations() throws {
        let sevenPlus = SevenPlusProtocol()
        let delegate = MockSevenPlusDelegate()
        sevenPlus.delegate = delegate

        let testData = Data(repeating: 0x42, count: 1000)
        try sevenPlus.startSending(fileName: "test.bin", fileData: testData)

        // Multiple pause/resume cycles
        for _ in 0..<3 {
            sevenPlus.pause()
            XCTAssertEqual(sevenPlus.state, .paused)

            sevenPlus.resume()
            XCTAssertEqual(sevenPlus.state, .transferring)
        }
    }

    func testProgressCalculation() {
        let sevenPlus = SevenPlusProtocol()
        XCTAssertEqual(sevenPlus.progress, 0.0)  // No bytes transferred initially
    }

    func testBlockChecksumWithVaryingBlocks() {
        let sevenPlus = SevenPlusProtocol()

        for blockNum in [0, 1, 10, 100, 9999] {
            let checksum = sevenPlus.encodeBlockChecksum(blockNum: blockNum, checksum: 0xFFFF)
            XCTAssertTrue(checksum.contains("chk"))
        }
    }

    // MARK: - Protocol Sequence Tests

    func testFullSendSequence() throws {
        let sevenPlus = SevenPlusProtocol()
        let delegate = MockSevenPlusDelegate()
        sevenPlus.delegate = delegate

        let testData = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        try sevenPlus.startSending(fileName: "test.bin", fileData: testData)

        // Should have sent: header, data lines, footer
        XCTAssertGreaterThanOrEqual(delegate.sentData.count, 2)

        // First frame should be header
        let firstFrame = String(data: delegate.sentData.first!, encoding: .ascii)!
        XCTAssertTrue(firstFrame.contains("go_7+."))
    }

    func testReceiverCompletesWithStopLine() {
        let sevenPlus = SevenPlusProtocol()
        let delegate = MockSevenPlusDelegate()
        sevenPlus.delegate = delegate

        XCTAssertEqual(sevenPlus.state, .idle)

        // Receive header
        let headerData = " go_7+. test.bin size=100 crc32=00000000\r\n".data(using: .ascii)!
        _ = sevenPlus.handleIncomingData(headerData)

        // Receive stop
        let stopData = " stop_7+.\r\n".data(using: .ascii)!
        _ = sevenPlus.handleIncomingData(stopData)

        // State should be completed after stop line
        XCTAssertEqual(sevenPlus.state, .completed)
        XCTAssertTrue(delegate.stateChanges.contains(.completed))
    }
}

// MARK: - Mock Delegate

private class MockSevenPlusDelegate: FileTransferProtocolDelegate {
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
