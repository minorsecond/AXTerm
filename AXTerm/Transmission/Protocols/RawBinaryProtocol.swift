//
//  RawBinaryProtocol.swift
//  AXTerm
//
//  Simple raw binary file transfer protocol.
//  Sends file data directly in AX.25 I-frames with minimal framing.
//  Relies entirely on AX.25 connected mode for reliability.
//
//  This is the simplest fallback protocol when nothing else is available.
//

import Foundation
import CommonCrypto

// MARK: - Raw Binary Frame Types

/// Raw binary protocol frame markers
nonisolated enum RawBinaryMarker: UInt8 {
    case metadata = 0x7B  // '{' - Start of JSON metadata
    case eot = 0x04       // End of Transmission
}

/// Raw binary protocol state
nonisolated enum RawBinaryState: Equatable, Sendable {
    case idle
    case sendingMetadata
    case sendingData
    case waitingForEnd
    case receivingMetadata
    case receivingData
    case complete
    case failed(reason: String)
    case cancelled
}

// MARK: - Raw Binary Protocol Implementation

/// Simple raw binary file transfer protocol
nonisolated final class RawBinaryProtocol: FileTransferProtocol {
    let protocolType: TransferProtocolType = .rawBinary

    weak var delegate: FileTransferProtocolDelegate?

    private(set) var state: TransferProtocolState = .idle
    private(set) var bytesTransferred: Int = 0
    private(set) var totalBytes: Int = 0

    // Configuration
    private let chunkSize: Int = 230  // Leave room for AX.25 overhead

    // Sender state
    private var rawState: RawBinaryState = .idle
    private var fileName: String = ""
    private var fileData: Data = Data()
    private var currentOffset: Int = 0
    private var fileSHA256: Data = Data()

    // Receiver state
    private var receivedData: Data = Data()
    private var receivedFileName: String = ""
    private var receivedFileSize: Int = 0
    private var receivedSHA256: Data = Data()
    private var metadataBuffer: Data = Data()

    // MARK: - Initialization

    init() {
        // Default initializer
    }

    // MARK: - Protocol Detection

    static func canHandle(data: Data) -> Bool {
        // Raw binary is detected by JSON metadata start or EOT marker
        guard let firstNonWhitespace = firstNonWhitespaceByte(in: data) else { return false }

        // Check for JSON metadata start
        if firstNonWhitespace == RawBinaryMarker.metadata.rawValue {
            // Verify it looks like our JSON format
            if let str = String(data: data, encoding: .utf8),
               str.contains("\"filename\"") && str.contains("\"size\"") {
                return true
            }
        }

        // Check for EOT
        if firstNonWhitespace == RawBinaryMarker.eot.rawValue && data.count == 1 {
            return true
        }

        return false
    }

    // MARK: - Sender Side

    func startSending(fileName: String, fileData: Data) throws {
        guard rawState == .idle else {
            throw FileTransferError.invalidState(expected: "idle", actual: String(describing: rawState))
        }

        self.fileName = fileName
        self.fileData = fileData
        self.totalBytes = fileData.count
        self.bytesTransferred = 0
        self.currentOffset = 0

        // Calculate SHA-256
        self.fileSHA256 = computeSHA256(fileData)

        // Send metadata frame
        rawState = .sendingMetadata
        state = .transferring
        delegate?.transferProtocol(self, stateChanged: state)

        let metadataFrame = encodeMetadata(fileName: fileName, fileSize: fileData.count, sha256: fileSHA256)
        delegate?.transferProtocol(self, needsToSend: metadataFrame)

        // Immediately start sending data (no ACK in raw binary)
        rawState = .sendingData
        sendNextChunk()
    }

    func handleAck(data: Data) {
        // Raw binary doesn't use application-level ACKs
        // AX.25 L2 handles reliability
    }

    func handleNak(data: Data) {
        // Raw binary doesn't use application-level NAKs
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
            sendNextChunk()
        }
    }

    func cancel() {
        // Send EOT to signal cancellation
        let eotFrame = encodeEOT()
        delegate?.transferProtocol(self, needsToSend: eotFrame)

        rawState = .cancelled
        state = .cancelled
        delegate?.transferProtocol(self, stateChanged: state)
        delegate?.transferProtocol(self, didComplete: false, error: "Cancelled")
    }

    // MARK: - Receiver Side

    func handleIncomingData(_ data: Data) -> Bool {
        guard let firstNonWhitespace = Self.firstNonWhitespaceByte(in: data) else { return false }

        switch rawState {
        case .idle, .receivingMetadata:
            // Look for metadata
            if firstNonWhitespace == RawBinaryMarker.metadata.rawValue {
                if parseMetadata(data) {
                    rawState = .receivingData
                    receivedData = Data()
                    bytesTransferred = 0
                    state = .transferring
                    delegate?.transferProtocol(self, stateChanged: state)

                    // Request user confirmation
                    let metadata = TransferFileMetadata(
                        fileName: receivedFileName,
                        fileSize: receivedFileSize,
                        sha256: receivedSHA256,
                        protocolType: .rawBinary
                    )
                    delegate?.transferProtocol(self, requestsConfirmation: metadata)
                    return true
                }
            }
            return false

        case .receivingData:
            // Check for EOT
            if firstNonWhitespace == RawBinaryMarker.eot.rawValue && data.count == 1 {
                return handleEndOfTransmission()
            }

            // Accumulate data
            receivedData.append(data)
            bytesTransferred = receivedData.count
            delegate?.transferProtocol(self, didUpdateProgress: progress, bytesSent: bytesTransferred)
            return true

        default:
            return false
        }
    }

    func acceptTransfer() {
        // Raw binary doesn't have explicit accept - data just flows
        // This is called by UI but doesn't change protocol behavior
    }

    func rejectTransfer(reason: String) {
        rawState = .cancelled
        state = .cancelled
        delegate?.transferProtocol(self, stateChanged: state)
    }

    // MARK: - Frame Encoding

    /// Encode metadata frame as JSON
    func encodeMetadata(fileName: String, fileSize: Int, sha256: Data) -> Data {
        let sha256Hex = sha256.map { String(format: "%02x", $0) }.joined()
        let json = "{\"filename\":\"\(escapeJSON(fileName))\",\"size\":\(fileSize),\"sha256\":\"\(sha256Hex)\"}"
        return json.data(using: .utf8) ?? Data()
    }

    /// Encode EOT frame
    func encodeEOT() -> Data {
        Data([RawBinaryMarker.eot.rawValue])
    }

    // MARK: - Frame Parsing

    /// Parse metadata from JSON frame
    private func parseMetadata(_ data: Data) -> Bool {
        guard let jsonString = String(data: data, encoding: .utf8) else { return false }

        // Simple JSON parsing (avoiding JSONDecoder for minimal overhead)
        guard let filenameMatch = extractJSONString(jsonString, key: "filename"),
              let sizeMatch = extractJSONInt(jsonString, key: "size") else {
            return false
        }

        receivedFileName = filenameMatch
        receivedFileSize = sizeMatch
        totalBytes = sizeMatch

        // SHA-256 is optional
        if let sha256Hex = extractJSONString(jsonString, key: "sha256") {
            receivedSHA256 = hexToData(sha256Hex)
        }

        return true
    }

    /// Handle end of transmission
    private func handleEndOfTransmission() -> Bool {
        rawState = .complete
        state = .completed
        delegate?.transferProtocol(self, stateChanged: state)

        // Verify SHA-256 if provided
        if !receivedSHA256.isEmpty {
            let calculatedData = computeSHA256(receivedData)

            if calculatedData != receivedSHA256 {
                state = .failed(reason: "SHA-256 checksum mismatch")
                delegate?.transferProtocol(self, stateChanged: state)
                delegate?.transferProtocol(self, didComplete: false, error: "Checksum mismatch - file corrupted")
                return true
            }
        }

        let metadata = TransferFileMetadata(
            fileName: receivedFileName,
            fileSize: receivedData.count,
            sha256: receivedSHA256.isEmpty ? nil : receivedSHA256,
            protocolType: .rawBinary
        )
        delegate?.transferProtocol(self, didReceiveFile: receivedData, metadata: metadata)
        delegate?.transferProtocol(self, didComplete: true, error: nil)
        return true
    }

    // MARK: - Private Helpers

    private func sendNextChunk() {
        guard state == .transferring else { return }
        guard currentOffset < fileData.count else {
            // All data sent, send EOT
            let eotFrame = encodeEOT()
            delegate?.transferProtocol(self, needsToSend: eotFrame)

            rawState = .complete
            state = .completed
            delegate?.transferProtocol(self, stateChanged: state)
            delegate?.transferProtocol(self, didComplete: true, error: nil)
            return
        }

        let end = min(currentOffset + chunkSize, fileData.count)
        let chunk = fileData.subdata(in: currentOffset..<end)

        delegate?.transferProtocol(self, needsToSend: chunk)

        currentOffset = end
        bytesTransferred = currentOffset
        delegate?.transferProtocol(self, didUpdateProgress: progress, bytesSent: bytesTransferred)

        // Schedule next chunk (allows AX.25 to process)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.sendNextChunk()
        }
    }

    /// Escape string for JSON
    private func escapeJSON(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func firstNonWhitespaceByte(in data: Data) -> UInt8? {
        for byte in data {
            switch byte {
            case 0x09, 0x0A, 0x0D, 0x20:
                continue
            default:
                return byte
            }
        }
        return nil
    }

    /// Extract string value from JSON
    private func extractJSONString(_ json: String, key: String) -> String? {
        let pattern = "\"\(key)\":\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let range = Range(match.range(at: 1), in: json) else {
            return nil
        }
        return String(json[range])
    }

    /// Extract int value from JSON
    private func extractJSONInt(_ json: String, key: String) -> Int? {
        let pattern = "\"\(key)\":(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
              let range = Range(match.range(at: 1), in: json) else {
            return nil
        }
        return Int(json[range])
    }

    /// Convert hex string to Data
    private func hexToData(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        return data
    }

    /// Compute SHA-256 hash using CommonCrypto
    private func computeSHA256(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }
}
