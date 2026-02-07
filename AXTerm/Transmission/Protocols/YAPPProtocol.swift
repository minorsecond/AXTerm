//
//  YAPPProtocol.swift
//  AXTerm
//
//  YAPP (Yet Another Packet Protocol) implementation for legacy file transfers.
//  YAPP is a binary protocol with ACK/NAK flow control, commonly supported by
//  classic packet terminal software.
//
//  Protocol Reference: YAPP specification (various implementations)
//  Control bytes: SOH (0x01), STX (0x02), ETX (0x03), EOT (0x04), ACK (0x06), NAK (0x15), CAN (0x18)
//

import Foundation

// MARK: - YAPP Constants

/// YAPP protocol control characters
enum YAPPControlChar: UInt8 {
    case soh = 0x01  // Start of Header
    case stx = 0x02  // Start of Text (data block)
    case etx = 0x03  // End of Text (end of file)
    case eot = 0x04  // End of Transmission
    case ack = 0x06  // Acknowledge
    case nak = 0x15  // Negative Acknowledge
    case can = 0x18  // Cancel
}

/// YAPP frame types
enum YAPPFrameType: Equatable {
    case sendInit           // SI: [SOH, 0x01] - Request to start transfer
    case receiveInit        // RI: [SOH, 0x02] - Ready to receive
    case header             // HD: [SOH, len, filename\0, size\0, timestamp\0]
    case data               // DT: [STX, len_hi, len_lo, data..., checksum]
    case endFile            // EF: [ETX, 0x01]
    case endTransmission    // ET: [EOT]
    case ack                // ACK: [ACK]
    case nak                // NAK: [NAK]
    case cancel             // CAN: [CAN]
    case unknown
}

/// YAPP sender state machine
enum YAPPSenderState: Equatable, Sendable {
    case idle
    case waitingForReceiveInit   // Sent SI, waiting for RI
    case waitingForHeaderAck     // Sent HD, waiting for ACK
    case sendingData             // Sending DT blocks
    case waitingForDataAck       // Sent DT, waiting for ACK
    case waitingForEndFileAck    // Sent EF, waiting for ACK
    case complete
    case failed(reason: String)
    case cancelled
}

/// YAPP receiver state machine
enum YAPPReceiverState: Equatable, Sendable {
    case idle
    case waitingForHeader        // Received SI, sent RI, waiting for HD
    case waitingForUserAccept    // Received HD, waiting for user to accept
    case receivingData           // Receiving DT blocks
    case complete
    case failed(reason: String)
    case cancelled
}

// MARK: - YAPP Protocol Implementation

/// YAPP file transfer protocol implementation
final class YAPPProtocol: FileTransferProtocol {
    let protocolType: TransferProtocolType = .yapp

    weak var delegate: FileTransferProtocolDelegate?

    private(set) var state: TransferProtocolState = .idle
    private(set) var bytesTransferred: Int = 0
    private(set) var totalBytes: Int = 0

    // Configuration
    private let maxBlockSize: Int = 250  // YAPP typical max block size
    private let maxRetries: Int = 10
    private let ackTimeout: TimeInterval = 30.0

    // Sender state
    private var senderState: YAPPSenderState = .idle
    private var pausedState: TransferProtocolState?
    private var fileName: String = ""
    private var fileData: Data = Data()
    private var currentBlockIndex: Int = 0
    private var retryCount: Int = 0
    private var ackTimer: Timer?

    // Receiver state
    private var receiverState: YAPPReceiverState = .idle
    private var receivedData: Data = Data()
    private var receivedFileName: String = ""
    private var receivedFileSize: Int = 0
    private var receivedTimestamp: Date?

    deinit {
        ackTimer?.invalidate()
    }

    // MARK: - Protocol Detection

    static func canHandle(data: Data) -> Bool {
        guard let firstByte = data.first else { return false }

        // YAPP frames start with control characters
        switch firstByte {
        case YAPPControlChar.soh.rawValue,
             YAPPControlChar.stx.rawValue,
             YAPPControlChar.etx.rawValue,
             YAPPControlChar.eot.rawValue,
             YAPPControlChar.ack.rawValue,
             YAPPControlChar.nak.rawValue,
             YAPPControlChar.can.rawValue:
            return true
        default:
            return false
        }
    }

    // MARK: - Sender Side

    func startSending(fileName: String, fileData: Data) throws {
        guard senderState == .idle else {
            throw FileTransferError.invalidState(expected: "idle", actual: String(describing: senderState))
        }

        self.fileName = fileName
        self.fileData = fileData
        self.totalBytes = fileData.count
        self.bytesTransferred = 0
        self.currentBlockIndex = 0
        self.retryCount = 0

        // Send SI (Send Init)
        let siFrame = encodeSendInit()
        senderState = .waitingForReceiveInit
        state = .waitingForAccept
        delegate?.transferProtocol(self, stateChanged: state)
        delegate?.transferProtocol(self, needsToSend: siFrame)

        startAckTimer()
    }

    func handleAck(data: Data) {
        guard let frameType = parseFrameType(data) else { return }

        ackTimer?.invalidate()
        retryCount = 0

        switch (senderState, frameType) {
        case (.waitingForReceiveInit, .receiveInit):
            // Peer ready, send header
            senderState = .waitingForHeaderAck
            let headerFrame = encodeHeader(fileName: fileName, fileSize: totalBytes)
            delegate?.transferProtocol(self, needsToSend: headerFrame)
            startAckTimer()

        case (.waitingForHeaderAck, .ack):
            // Header accepted, start sending data
            senderState = .sendingData
            state = .transferring
            delegate?.transferProtocol(self, stateChanged: state)
            sendNextBlock()

        case (.waitingForDataAck, .ack):
            // Block acknowledged, send next
            currentBlockIndex += 1
            if hasMoreBlocks {
                sendNextBlock()
            } else {
                // All blocks sent, send end of file
                senderState = .waitingForEndFileAck
                let efFrame = encodeEndFile()
                delegate?.transferProtocol(self, needsToSend: efFrame)
                startAckTimer()
            }

        case (.waitingForEndFileAck, .ack):
            // Transfer complete, send end of transmission
            let etFrame = encodeEndTransmission()
            delegate?.transferProtocol(self, needsToSend: etFrame)
            senderState = .complete
            state = .completed
            delegate?.transferProtocol(self, stateChanged: state)
            delegate?.transferProtocol(self, didComplete: true, error: nil)

        default:
            break
        }
    }

    func handleNak(data: Data) {
        guard let frameType = parseFrameType(data) else { return }

        ackTimer?.invalidate()

        switch frameType {
        case .nak:
            retryCount += 1
            if retryCount > maxRetries {
                handleFailure(reason: "Maximum retries exceeded")
                return
            }
            // Retransmit current block
            retransmitCurrentBlock()

        case .cancel:
            senderState = .cancelled
            state = .cancelled
            delegate?.transferProtocol(self, stateChanged: state)
            delegate?.transferProtocol(self, didComplete: false, error: "Cancelled by peer")

        default:
            break
        }
    }

    func pause() {
        guard state.isActive, state != .paused else { return }
        pausedState = state
        ackTimer?.invalidate()
        state = .paused
        delegate?.transferProtocol(self, stateChanged: state)
    }

    func resume() {
        guard state == .paused else { return }
        let restored = pausedState ?? .transferring
        pausedState = nil
        state = restored
        delegate?.transferProtocol(self, stateChanged: state)

        switch restored {
        case .transferring:
            retransmitCurrentBlock()
        case .waitingForAccept, .waitingForAck:
            startAckTimer()
        default:
            break
        }
    }

    func cancel() {
        ackTimer?.invalidate()
        let cancelFrame = encodeCancel()
        delegate?.transferProtocol(self, needsToSend: cancelFrame)
        senderState = .cancelled
        state = .cancelled
        delegate?.transferProtocol(self, stateChanged: state)
        delegate?.transferProtocol(self, didComplete: false, error: "Cancelled")
    }

    // MARK: - Receiver Side

    func handleIncomingData(_ data: Data) -> Bool {
        guard Self.canHandle(data: data) else { return false }
        guard let frameType = parseFrameType(data) else { return false }

        switch (receiverState, frameType) {
        case (.idle, .sendInit):
            // Peer wants to send, reply with RI
            receiverState = .waitingForHeader
            let riFrame = encodeReceiveInit()
            delegate?.transferProtocol(self, needsToSend: riFrame)
            return true

        case (.waitingForHeader, .header):
            // Parse header and request user confirmation
            if let (name, size, timestamp) = parseHeader(data) {
                receivedFileName = name
                receivedFileSize = size
                receivedTimestamp = timestamp
                totalBytes = size
                receiverState = .waitingForUserAccept

                let metadata = TransferFileMetadata(
                    fileName: name,
                    fileSize: size,
                    timestamp: timestamp,
                    protocolType: .yapp
                )
                delegate?.transferProtocol(self, requestsConfirmation: metadata)
            } else {
                // Invalid header, NAK
                let nakFrame = encodeNak()
                delegate?.transferProtocol(self, needsToSend: nakFrame)
            }
            return true

        case (.receivingData, .data):
            // Receive data block
            if let blockData = parseDataBlock(data) {
                receivedData.append(blockData)
                bytesTransferred = receivedData.count
                delegate?.transferProtocol(self, didUpdateProgress: progress, bytesSent: bytesTransferred)

                // ACK the block
                let ackFrame = encodeAck()
                delegate?.transferProtocol(self, needsToSend: ackFrame)
            } else {
                // Checksum error, NAK
                let nakFrame = encodeNak()
                delegate?.transferProtocol(self, needsToSend: nakFrame)
            }
            return true

        case (.receivingData, .endFile):
            // End of file received
            let ackFrame = encodeAck()
            delegate?.transferProtocol(self, needsToSend: ackFrame)
            return true

        case (.receivingData, .endTransmission):
            // Transfer complete
            receiverState = .complete
            state = .completed
            delegate?.transferProtocol(self, stateChanged: state)

            let metadata = TransferFileMetadata(
                fileName: receivedFileName,
                fileSize: receivedData.count,
                timestamp: receivedTimestamp,
                protocolType: .yapp
            )
            delegate?.transferProtocol(self, didReceiveFile: receivedData, metadata: metadata)
            delegate?.transferProtocol(self, didComplete: true, error: nil)
            return true

        case (_, .cancel):
            // Peer cancelled
            receiverState = .cancelled
            state = .cancelled
            delegate?.transferProtocol(self, stateChanged: state)
            delegate?.transferProtocol(self, didComplete: false, error: "Cancelled by peer")
            return true

        default:
            return false
        }
    }

    func acceptTransfer() {
        guard receiverState == .waitingForUserAccept else { return }

        receiverState = .receivingData
        receivedData = Data()
        bytesTransferred = 0
        state = .transferring
        delegate?.transferProtocol(self, stateChanged: state)

        // Send ACK to accept header
        let ackFrame = encodeAck()
        delegate?.transferProtocol(self, needsToSend: ackFrame)
    }

    func rejectTransfer(reason: String) {
        guard receiverState == .waitingForUserAccept else { return }

        receiverState = .cancelled
        state = .cancelled
        delegate?.transferProtocol(self, stateChanged: state)

        // Send CAN to reject
        let cancelFrame = encodeCancel()
        delegate?.transferProtocol(self, needsToSend: cancelFrame)
    }

    // MARK: - Frame Encoding

    /// Encode SI (Send Init) frame: [SOH, 0x01]
    func encodeSendInit() -> Data {
        Data([YAPPControlChar.soh.rawValue, 0x01])
    }

    /// Encode RI (Receive Init) frame: [SOH, 0x02]
    func encodeReceiveInit() -> Data {
        Data([YAPPControlChar.soh.rawValue, 0x02])
    }

    /// Encode header frame: [SOH, len, filename\0, size_ascii\0, timestamp\0]
    func encodeHeader(fileName: String, fileSize: Int, timestamp: Date? = nil) -> Data {
        var payload = Data()

        // Filename (null-terminated)
        if let filenameData = fileName.data(using: .ascii) {
            payload.append(filenameData)
        }
        payload.append(0x00)

        // File size as ASCII decimal (null-terminated)
        let sizeString = String(fileSize)
        if let sizeData = sizeString.data(using: .ascii) {
            payload.append(sizeData)
        }
        payload.append(0x00)

        // Timestamp (optional, null-terminated)
        if let ts = timestamp {
            let tsString = String(Int(ts.timeIntervalSince1970))
            if let tsData = tsString.data(using: .ascii) {
                payload.append(tsData)
            }
        }
        payload.append(0x00)

        // Build frame: [SOH, len, payload]
        var frame = Data()
        frame.append(YAPPControlChar.soh.rawValue)
        frame.append(UInt8(min(payload.count, 255)))
        frame.append(payload)

        return frame
    }

    /// Encode data block: [STX, len_hi, len_lo, data..., checksum]
    func encodeDataBlock(data: Data) -> Data {
        var frame = Data()
        frame.append(YAPPControlChar.stx.rawValue)

        // Length (2 bytes, big endian)
        let len = UInt16(data.count)
        frame.append(UInt8((len >> 8) & 0xFF))
        frame.append(UInt8(len & 0xFF))

        // Data
        frame.append(data)

        // Checksum (XOR of all data bytes)
        let checksum = calculateChecksum(data)
        frame.append(checksum)

        return frame
    }

    /// Encode end of file: [ETX, 0x01]
    func encodeEndFile() -> Data {
        Data([YAPPControlChar.etx.rawValue, 0x01])
    }

    /// Encode end of transmission: [EOT]
    func encodeEndTransmission() -> Data {
        Data([YAPPControlChar.eot.rawValue])
    }

    /// Encode ACK: [ACK]
    func encodeAck() -> Data {
        Data([YAPPControlChar.ack.rawValue])
    }

    /// Encode NAK: [NAK]
    func encodeNak() -> Data {
        Data([YAPPControlChar.nak.rawValue])
    }

    /// Encode Cancel: [CAN]
    func encodeCancel() -> Data {
        Data([YAPPControlChar.can.rawValue])
    }

    // MARK: - Frame Parsing

    /// Parse frame type from data
    func parseFrameType(_ data: Data) -> YAPPFrameType? {
        guard let firstByte = data.first else { return nil }

        switch firstByte {
        case YAPPControlChar.soh.rawValue:
            if data.count >= 2 {
                switch data[1] {
                case 0x01: return .sendInit
                case 0x02: return .receiveInit
                default: return .header  // Header has variable length
                }
            }
            return .header

        case YAPPControlChar.stx.rawValue:
            return .data

        case YAPPControlChar.etx.rawValue:
            return .endFile

        case YAPPControlChar.eot.rawValue:
            return .endTransmission

        case YAPPControlChar.ack.rawValue:
            return .ack

        case YAPPControlChar.nak.rawValue:
            return .nak

        case YAPPControlChar.can.rawValue:
            return .cancel

        default:
            return .unknown
        }
    }

    /// Parse header frame to extract filename, size, and timestamp
    func parseHeader(_ data: Data) -> (fileName: String, fileSize: Int, timestamp: Date?)? {
        // Header format: [SOH, len, filename\0, size\0, timestamp\0]
        guard data.count >= 3 else { return nil }
        guard data[0] == YAPPControlChar.soh.rawValue else { return nil }

        let len = Int(data[1])
        guard data.count >= 2 + len else { return nil }

        let payload = data.subdata(in: 2..<(2 + len))

        // Find null terminators
        var parts: [String] = []
        var currentStart = 0

        for i in 0..<payload.count {
            if payload[i] == 0x00 {
                if let str = String(data: payload.subdata(in: currentStart..<i), encoding: .ascii) {
                    parts.append(str)
                }
                currentStart = i + 1
            }
        }

        guard parts.count >= 2 else { return nil }

        let fileName = parts[0]
        guard let fileSize = Int(parts[1]) else { return nil }

        var timestamp: Date?
        if parts.count >= 3, let ts = Int(parts[2]) {
            timestamp = Date(timeIntervalSince1970: TimeInterval(ts))
        }

        return (fileName, fileSize, timestamp)
    }

    /// Parse data block to extract data (validates checksum)
    func parseDataBlock(_ data: Data) -> Data? {
        // Data format: [STX, len_hi, len_lo, data..., checksum]
        guard data.count >= 4 else { return nil }
        guard data[0] == YAPPControlChar.stx.rawValue else { return nil }

        let len = (Int(data[1]) << 8) | Int(data[2])
        guard data.count >= 3 + len + 1 else { return nil }

        let blockData = data.subdata(in: 3..<(3 + len))
        let receivedChecksum = data[3 + len]

        let expectedChecksum = calculateChecksum(blockData)
        guard receivedChecksum == expectedChecksum else {
            return nil  // Checksum mismatch
        }

        return blockData
    }

    // MARK: - Checksum

    /// Calculate XOR checksum of data
    func calculateChecksum(_ data: Data) -> UInt8 {
        data.reduce(0) { $0 ^ $1 }
    }

    // MARK: - Private Helpers

    private var hasMoreBlocks: Bool {
        let offset = currentBlockIndex * maxBlockSize
        return offset < fileData.count
    }

    private func sendNextBlock() {
        let offset = currentBlockIndex * maxBlockSize
        guard offset < fileData.count else { return }

        let end = min(offset + maxBlockSize, fileData.count)
        let blockData = fileData.subdata(in: offset..<end)

        senderState = .waitingForDataAck
        let dataFrame = encodeDataBlock(data: blockData)
        delegate?.transferProtocol(self, needsToSend: dataFrame)

        bytesTransferred = end
        delegate?.transferProtocol(self, didUpdateProgress: progress, bytesSent: bytesTransferred)

        startAckTimer()
    }

    private func retransmitCurrentBlock() {
        if senderState == .waitingForReceiveInit {
            let siFrame = encodeSendInit()
            delegate?.transferProtocol(self, needsToSend: siFrame)
        } else if senderState == .waitingForHeaderAck {
            let headerFrame = encodeHeader(fileName: fileName, fileSize: totalBytes)
            delegate?.transferProtocol(self, needsToSend: headerFrame)
        } else if senderState == .waitingForDataAck {
            sendNextBlock()
        } else if senderState == .waitingForEndFileAck {
            let efFrame = encodeEndFile()
            delegate?.transferProtocol(self, needsToSend: efFrame)
        }
        startAckTimer()
    }

    private func startAckTimer() {
        ackTimer?.invalidate()
        ackTimer = Timer.scheduledTimer(withTimeInterval: ackTimeout, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }
    }

    private func handleTimeout() {
        retryCount += 1
        if retryCount > maxRetries {
            handleFailure(reason: "Timeout - no response from peer")
        } else {
            retransmitCurrentBlock()
        }
    }

    private func handleFailure(reason: String) {
        ackTimer?.invalidate()
        senderState = .failed(reason: reason)
        state = .failed(reason: reason)
        delegate?.transferProtocol(self, stateChanged: state)
        delegate?.transferProtocol(self, didComplete: false, error: reason)
    }
}
