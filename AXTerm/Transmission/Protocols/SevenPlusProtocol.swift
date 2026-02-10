//
//  SevenPlusProtocol.swift
//  AXTerm
//
//  7plus ASCII encoding protocol for file transfers over 7-bit clean paths.
//  Used primarily for BBS message forwarding where binary data must be
//  encoded as printable ASCII characters.
//
//  Protocol Reference: 7plus specification (Langstrasse software)
//  Encoding: 3 bytes → 4 ASCII characters (similar to Base64 but different charset)
//

import Foundation
import CommonCrypto

// MARK: - 7plus Constants

/// 7plus encoding character set (custom, not standard Base64)
/// Uses characters that are safe for 7-bit ASCII transmission
nonisolated private let sevenPlusCharset: [Character] = Array(
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz@#"
)

/// Lines per block for checksumming
nonisolated private let linesPerBlock: Int = 32

/// Maximum encoded line length
private let maxLineLength: Int = 64

// MARK: - 7plus State

/// 7plus protocol state
nonisolated enum SevenPlusState: Equatable, Sendable {
    case idle
    case sendingHeader
    case sendingData
    case sendingFooter
    case receivingHeader
    case receivingData
    case complete
    case failed(reason: String)
    case cancelled
}

// MARK: - 7plus Protocol Implementation

/// 7plus ASCII encoding file transfer protocol
nonisolated final class SevenPlusProtocol: FileTransferProtocol {
    let protocolType: TransferProtocolType = .sevenPlus

    weak var delegate: FileTransferProtocolDelegate?

    private(set) var state: TransferProtocolState = .idle
    private(set) var bytesTransferred: Int = 0
    private(set) var totalBytes: Int = 0

    // Configuration
    private let bytesPerLine: Int = 48  // 48 bytes encode to 64 chars

    // Sender state
    private var sevenPlusState: SevenPlusState = .idle
    private var fileName: String = ""
    private var fileData: Data = Data()
    private var currentOffset: Int = 0
    private var currentLine: Int = 0
    private var fileCRC32: UInt32 = 0

    // Receiver state
    private var receivedData: Data = Data()
    private var receivedFileName: String = ""
    private var receivedFileSize: Int = 0
    private var receivedCRC32: UInt32 = 0
    private var lineBuffer: String = ""
    private var inDataSection: Bool = false

    // MARK: - Protocol Detection

    static func canHandle(data: Data) -> Bool {
        guard let str = String(data: data, encoding: .ascii) else { return false }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)

        // 7plus files start with header line
        if trimmed.hasPrefix("7PLUS ") || trimmed.hasPrefix("go_7+.") || trimmed.hasPrefix(" go_7+.") {
            return true
        }

        // Or the standard uuencode-style begin line we support
        if trimmed.hasPrefix("begin ") {
            return true
        }

        // Check for our specific header format
        if trimmed.contains("7PLUS v") && trimmed.contains("size=") {
            return true
        }

        return false
    }

    // MARK: - Sender Side

    func startSending(fileName: String, fileData: Data) throws {
        guard sevenPlusState == .idle else {
            throw FileTransferError.invalidState(expected: "idle", actual: String(describing: sevenPlusState))
        }

        self.fileName = fileName
        self.fileData = fileData
        self.totalBytes = fileData.count
        self.bytesTransferred = 0
        self.currentOffset = 0
        self.currentLine = 0

        // Calculate CRC32
        self.fileCRC32 = crc32(fileData)

        // Send header
        sevenPlusState = .sendingHeader
        state = .transferring
        delegate?.transferProtocol(self, stateChanged: state)

        let headerLine = encodeHeader(fileName: fileName, fileSize: fileData.count, crc32: fileCRC32)
        delegate?.transferProtocol(self, needsToSend: headerLine.data(using: .ascii) ?? Data())

        // Start sending data lines
        sevenPlusState = .sendingData
        sendNextLine()
    }

    func handleAck(data: Data) {
        // 7plus uses line-by-line transmission, no explicit ACKs
        // Block checksums allow selective retry
    }

    func handleNak(data: Data) {
        // Check if this is a retry request for a specific block
        if let str = String(data: data, encoding: .ascii),
           str.hasPrefix("RETRY ") {
            if let blockNum = Int(str.dropFirst(6).trimmingCharacters(in: .whitespaces)) {
                retransmitBlock(blockNum)
            }
        }
    }

    func pause() {
        if state == .transferring {
            state = .paused
            delegate?.transferProtocol(self, stateChanged: state)
        }
    }

    func resume() {
        if state == .paused {
            state = .transferring
            delegate?.transferProtocol(self, stateChanged: state)
            sendNextLine()
        }
    }

    func cancel() {
        // Send cancel line
        let cancelLine = " stop_7+.\r\n"
        delegate?.transferProtocol(self, needsToSend: cancelLine.data(using: .ascii) ?? Data())

        sevenPlusState = .cancelled
        state = .cancelled
        delegate?.transferProtocol(self, stateChanged: state)
        delegate?.transferProtocol(self, didComplete: false, error: "Cancelled")
    }

    // MARK: - Receiver Side

    func handleIncomingData(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .ascii) else { return false }

        // Process each line
        let lines = str.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if processLine(trimmed) == false {
                return false
            }
        }

        return true
    }

    func acceptTransfer() {
        // 7plus doesn't have explicit accept mechanism
        // Transfer starts as soon as data arrives
    }

    func rejectTransfer(reason: String) {
        sevenPlusState = .cancelled
        state = .cancelled
        delegate?.transferProtocol(self, stateChanged: state)
    }

    // MARK: - Encoding

    /// Encode header line
    func encodeHeader(fileName: String, fileSize: Int, crc32: UInt32) -> String {
        let crcHex = String(format: "%08X", crc32)
        return " go_7+. \(fileName) size=\(fileSize) crc32=\(crcHex)\r\n"
    }

    /// Encode footer line
    func encodeFooter() -> String {
        " stop_7+.\r\n"
    }

    /// Encode a block checksum line
    func encodeBlockChecksum(blockNum: Int, checksum: UInt16) -> String {
        String(format: " chk%04d %04X\r\n", blockNum, checksum)
    }

    /// Encode binary data as 7plus ASCII line
    /// 3 bytes → 4 characters
    func encodeLine(_ data: Data) -> String {
        var result = ""
        var index = 0
        var checksumSum = 0

        while index < data.count {
            // Get up to 3 bytes
            let byte1 = data[index]
            let byte2 = index + 1 < data.count ? data[index + 1] : 0
            let byte3 = index + 2 < data.count ? data[index + 2] : 0

            // Encode to 4 characters (6 bits each)
            let c1 = (byte1 >> 2) & 0x3F
            let c2 = ((byte1 & 0x03) << 4) | ((byte2 >> 4) & 0x0F)
            let c3 = ((byte2 & 0x0F) << 2) | ((byte3 >> 6) & 0x03)
            let c4 = byte3 & 0x3F

            result.append(sevenPlusCharset[Int(c1)])
            result.append(sevenPlusCharset[Int(c2)])
            checksumSum += Int(c1)
            checksumSum += Int(c2)

            if index + 1 < data.count {
                result.append(sevenPlusCharset[Int(c3)])
                checksumSum += Int(c3)
            }
            if index + 2 < data.count {
                result.append(sevenPlusCharset[Int(c4)])
                checksumSum += Int(c4)
            }

            index += 3
        }

        // Add line checksum (sum of all encoded values mod 64)
        let lineSum = checksumSum % 64
        result.append(sevenPlusCharset[lineSum])

        return result + "\r\n"
    }

    /// Decode a 7plus ASCII line back to binary
    func decodeLine(_ line: String) -> Data? {
        let chars = Array(line)
        guard chars.count >= 5 else { return nil }  // Minimum: 4 data chars + 1 checksum

        // Verify line checksum
        let dataChars = Array(chars.dropLast())
        let checksumChar = chars.last!
        var dataIndices: [Int] = []
        dataIndices.reserveCapacity(dataChars.count)

        for char in dataChars {
            guard let index = sevenPlusCharset.firstIndex(of: char) else {
                return nil
            }
            dataIndices.append(index)
        }

        let expectedSum = dataIndices.reduce(0, +) % 64

        guard let checksumIndex = sevenPlusCharset.firstIndex(of: checksumChar),
              checksumIndex == expectedSum else {
            return nil  // Checksum mismatch
        }

        // Decode data
        var result = Data()
        var index = 0

        while index + 3 < dataIndices.count {
            let i1 = dataIndices[index]
            let i2 = dataIndices[index + 1]
            let i3 = dataIndices[index + 2]
            let i4 = dataIndices[index + 3]
            let byte1 = UInt8((i1 << 2) | (i2 >> 4))
            let byte2 = UInt8(((i2 & 0x0F) << 4) | (i3 >> 2))
            let byte3 = UInt8(((i3 & 0x03) << 6) | i4)

            result.append(byte1)
            result.append(byte2)
            result.append(byte3)

            index += 4
        }

        // Handle remaining characters (partial group)
        let remaining = dataIndices.count - index
        if remaining >= 2 {
            let i1 = dataIndices[index]
            let i2 = dataIndices[index + 1]
            let byte1 = UInt8((i1 << 2) | (i2 >> 4))
            result.append(byte1)

            if remaining >= 3 {
                let i3 = dataIndices[index + 2]
                let byte2 = UInt8(((i2 & 0x0F) << 4) | (i3 >> 2))
                result.append(byte2)
            }
        }

        return result
    }

    // MARK: - Private Helpers

    private func sendNextLine() {
        guard state == .transferring else { return }
        guard currentOffset < fileData.count else {
            // All data sent, send footer
            sevenPlusState = .sendingFooter
            let footerLine = encodeFooter()
            delegate?.transferProtocol(self, needsToSend: footerLine.data(using: .ascii) ?? Data())

            sevenPlusState = .complete
            state = .completed
            delegate?.transferProtocol(self, stateChanged: state)
            delegate?.transferProtocol(self, didComplete: true, error: nil)
            return
        }

        // Get next line's worth of data
        let end = min(currentOffset + bytesPerLine, fileData.count)
        let lineData = fileData.subdata(in: currentOffset..<end)

        let encodedLine = encodeLine(lineData)
        delegate?.transferProtocol(self, needsToSend: encodedLine.data(using: .ascii) ?? Data())

        currentOffset = end
        currentLine += 1
        bytesTransferred = currentOffset
        delegate?.transferProtocol(self, didUpdateProgress: progress, bytesSent: bytesTransferred)

        // Every N lines, send a block checksum
        if currentLine % linesPerBlock == 0 {
            let blockNum = currentLine / linesPerBlock
            let blockChecksum = calculateBlockChecksum(blockNum)
            let checksumLine = encodeBlockChecksum(blockNum: blockNum, checksum: blockChecksum)
            delegate?.transferProtocol(self, needsToSend: checksumLine.data(using: .ascii) ?? Data())
        }

        // Schedule next line
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.sendNextLine()
        }
    }

    private func retransmitBlock(_ blockNum: Int) {
        let startLine = (blockNum - 1) * linesPerBlock
        let startOffset = startLine * bytesPerLine
        let endOffset = min(startOffset + (linesPerBlock * bytesPerLine), fileData.count)

        guard startOffset < fileData.count else { return }

        // Retransmit block
        var offset = startOffset
        while offset < endOffset {
            let end = min(offset + bytesPerLine, fileData.count)
            let lineData = fileData.subdata(in: offset..<end)
            let encodedLine = encodeLine(lineData)
            delegate?.transferProtocol(self, needsToSend: encodedLine.data(using: .ascii) ?? Data())
            offset = end
        }

        // Send block checksum
        let blockChecksum = calculateBlockChecksum(blockNum)
        let checksumLine = encodeBlockChecksum(blockNum: blockNum, checksum: blockChecksum)
        delegate?.transferProtocol(self, needsToSend: checksumLine.data(using: .ascii) ?? Data())
    }

    private func calculateBlockChecksum(_ blockNum: Int) -> UInt16 {
        let startLine = (blockNum - 1) * linesPerBlock
        let startOffset = startLine * bytesPerLine
        let endOffset = min(startOffset + (linesPerBlock * bytesPerLine), fileData.count)

        guard startOffset < fileData.count else { return 0 }

        let blockData = fileData.subdata(in: startOffset..<endOffset)
        return crc16(blockData)
    }

    private func processLine(_ line: String) -> Bool {
        // Check for header
        if line.hasPrefix("go_7+.") || line.hasPrefix(" go_7+.") {
            return parseHeader(line)
        }

        // Check for footer
        if line.hasPrefix("stop_7+.") || line.hasPrefix(" stop_7+.") {
            return handleEndOfFile()
        }

        // Check for block checksum
        if line.hasPrefix("chk") || line.hasPrefix(" chk") {
            // Verify block checksum (optional - we trust the data)
            return true
        }

        // Data line
        if inDataSection {
            if let decoded = decodeLine(line) {
                receivedData.append(decoded)
                bytesTransferred = receivedData.count
                delegate?.transferProtocol(self, didUpdateProgress: progress, bytesSent: bytesTransferred)
            }
            return true
        }

        return false
    }

    private func parseHeader(_ line: String) -> Bool {
        // Parse: " go_7+. filename size=N crc32=XXXXXXXX"
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return false }

        // Extract filename (second part after " go_7+.")
        receivedFileName = String(parts[1])

        // Extract size
        for part in parts {
            if part.hasPrefix("size=") {
                let sizeStr = part.dropFirst(5)
                receivedFileSize = Int(sizeStr) ?? 0
                totalBytes = receivedFileSize
            }
            if part.hasPrefix("crc32=") {
                let crcStr = part.dropFirst(6)
                receivedCRC32 = UInt32(crcStr, radix: 16) ?? 0
            }
        }

        sevenPlusState = .receivingData
        inDataSection = true
        receivedData = Data()
        bytesTransferred = 0

        // Request user confirmation
        let metadata = TransferFileMetadata(
            fileName: receivedFileName,
            fileSize: receivedFileSize,
            protocolType: .sevenPlus
        )
        delegate?.transferProtocol(self, requestsConfirmation: metadata)

        return true
    }

    private func handleEndOfFile() -> Bool {
        inDataSection = false
        sevenPlusState = .complete
        state = .completed
        delegate?.transferProtocol(self, stateChanged: state)

        // Verify CRC32 if provided
        if receivedCRC32 != 0 {
            let calculatedCRC = crc32(receivedData)
            if calculatedCRC != receivedCRC32 {
                state = .failed(reason: "CRC32 mismatch")
                delegate?.transferProtocol(self, stateChanged: state)
                delegate?.transferProtocol(self, didComplete: false, error: "CRC32 mismatch - file corrupted")
                return true
            }
        }

        let metadata = TransferFileMetadata(
            fileName: receivedFileName,
            fileSize: receivedData.count,
            protocolType: .sevenPlus
        )
        delegate?.transferProtocol(self, didReceiveFile: receivedData, metadata: metadata)
        delegate?.transferProtocol(self, didComplete: true, error: nil)
        return true
    }

    // MARK: - CRC Calculations

    /// Calculate CRC32 (standard polynomial)
    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF

        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xEDB88320 : 0)
            }
        }

        return crc ^ 0xFFFFFFFF
    }

    /// Calculate CRC16 for block checksums
    private func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF

        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xA001 : 0)
            }
        }

        return crc
    }
}
