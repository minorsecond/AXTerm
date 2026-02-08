//
//  FileTransferProtocol.swift
//  AXTerm
//
//  Protocol abstraction for file transfer implementations (AXDP, YAPP, 7plus, Raw Binary).
//  Enables AXTerm to transfer files with both modern AXDP-capable stations and legacy
//  packet equipment using established protocols.
//
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md - "Everything must remain usable on
//  existing packet networks."
//

import Foundation

// MARK: - Transfer Protocol Type

/// Supported file transfer protocols
enum TransferProtocolType: String, CaseIterable, Sendable, Identifiable {
    /// Modern AXTerm Datagram Protocol (default, preferred)
    case axdp = "AXDP"

    /// Yet Another Packet Protocol - common legacy binary transfer protocol
    case yapp = "YAPP"

    /// 7plus ASCII encoding for 7-bit clean paths (BBS forwarding)
    case sevenPlus = "7plus"

    /// Simple raw binary over I-frames (minimal protocol)
    case rawBinary = "Raw"

    var id: String { rawValue }

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .axdp: return "AXDP"
        case .yapp: return "YAPP"
        case .sevenPlus: return "7plus"
        case .rawBinary: return "Raw Binary"
        }
    }

    /// Short description for UI
    var shortDescription: String {
        switch self {
        case .axdp: return "Modern AXTerm protocol with compression"
        case .yapp: return "Legacy binary protocol with ACK/NAK"
        case .sevenPlus: return "ASCII encoding for 7-bit paths"
        case .rawBinary: return "Simple binary, relies on AX.25 L2"
        }
    }

    /// Whether this protocol requires an established AX.25 connected session
    var requiresConnectedMode: Bool {
        switch self {
        case .axdp: return false  // Can use UI frames or connected mode
        case .yapp: return true   // Needs reliable transport
        case .sevenPlus: return true  // Designed for connected sessions
        case .rawBinary: return true  // Relies on L2 reliability
        }
    }

    /// Whether this protocol supports optional compression
    var supportsCompression: Bool {
        switch self {
        case .axdp: return true
        case .yapp, .sevenPlus, .rawBinary: return false
        }
    }

    /// Whether this protocol has built-in application-level acknowledgments
    var hasBuiltInAck: Bool {
        switch self {
        case .axdp: return true   // SACK bitmaps
        case .yapp: return true   // ACK/NAK per block
        case .sevenPlus: return true  // Block checksums with retry
        case .rawBinary: return false  // Relies entirely on AX.25 L2
        }
    }

    /// Typical overhead per data block (bytes)
    var typicalOverhead: Int {
        switch self {
        case .axdp: return 20  // TLV headers
        case .yapp: return 5   // STX + length + checksum
        case .sevenPlus: return 8  // ASCII expansion ~33% + checksums
        case .rawBinary: return 1  // Minimal framing
        }
    }
}

// MARK: - Transfer Protocol State

/// Common state representation for all transfer protocols
enum TransferProtocolState: Equatable, Sendable {
    /// Protocol is idle, no active transfer
    case idle

    /// Waiting for peer to accept transfer (sender side)
    case waitingForAccept

    /// Transfer accepted, sending/receiving data
    case transferring

    /// Waiting for acknowledgment (sender side)
    case waitingForAck

    /// Transfer paused by user
    case paused

    /// Transfer completed successfully
    case completed

    /// Transfer failed
    case failed(reason: String)

    /// Transfer cancelled by user or peer
    case cancelled

    /// Whether the transfer is in a terminal state
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    /// Whether the transfer is active (not terminal, not idle)
    var isActive: Bool {
        switch self {
        case .idle, .completed, .failed, .cancelled:
            return false
        default:
            return true
        }
    }
}

// MARK: - File Metadata

/// Metadata about a file being transferred
struct TransferFileMetadata: Sendable, Equatable {
    /// File name (sanitized, no path components)
    let fileName: String

    /// File size in bytes
    let fileSize: Int

    /// SHA-256 hash of file contents (optional, for verification)
    let sha256: Data?

    /// Timestamp of file (optional)
    let timestamp: Date?

    /// MIME type (optional)
    let mimeType: String?

    /// Transfer protocol being used
    let protocolType: TransferProtocolType

    init(
        fileName: String,
        fileSize: Int,
        sha256: Data? = nil,
        timestamp: Date? = nil,
        mimeType: String? = nil,
        protocolType: TransferProtocolType
    ) {
        // Sanitize filename - remove path components
        self.fileName = (fileName as NSString).lastPathComponent
        self.fileSize = fileSize
        self.sha256 = sha256
        self.timestamp = timestamp
        self.mimeType = mimeType
        self.protocolType = protocolType
    }
}

// MARK: - Protocol Delegate

/// Delegate protocol for receiving transfer protocol events
protocol FileTransferProtocolDelegate: AnyObject {
    /// Protocol needs to send data to the peer
    func transferProtocol(_ protocol: FileTransferProtocol, needsToSend data: Data)

    /// Progress has been updated
    func transferProtocol(_ protocol: FileTransferProtocol, didUpdateProgress progress: Double, bytesSent: Int)

    /// Transfer completed (successfully or with error)
    func transferProtocol(_ protocol: FileTransferProtocol, didComplete successfully: Bool, error: String?)

    /// Received a complete file (receiver side)
    func transferProtocol(_ protocol: FileTransferProtocol, didReceiveFile data: Data, metadata: TransferFileMetadata)

    /// Incoming transfer request needs user confirmation (receiver side)
    func transferProtocol(_ protocol: FileTransferProtocol, requestsConfirmation metadata: TransferFileMetadata)

    /// State changed
    func transferProtocol(_ protocol: FileTransferProtocol, stateChanged newState: TransferProtocolState)
}

// MARK: - File Transfer Protocol

/// Common interface for all file transfer protocol implementations
protocol FileTransferProtocol: AnyObject {
    /// The type of this protocol
    var protocolType: TransferProtocolType { get }

    /// Delegate for protocol events
    var delegate: FileTransferProtocolDelegate? { get set }

    /// Current state of the protocol
    var state: TransferProtocolState { get }

    /// Transfer progress (0.0 to 1.0)
    var progress: Double { get }

    /// Bytes successfully transferred
    var bytesTransferred: Int { get }

    /// Total bytes to transfer
    var totalBytes: Int { get }

    // MARK: - Sender Side

    /// Start sending a file
    /// - Parameters:
    ///   - fileName: Name of the file
    ///   - fileData: Contents of the file
    /// - Throws: If the transfer cannot be started
    func startSending(fileName: String, fileData: Data) throws

    /// Handle an acknowledgment from the peer
    /// - Parameter data: ACK frame data (protocol-specific format)
    func handleAck(data: Data)

    /// Handle a negative acknowledgment from the peer
    /// - Parameter data: NAK frame data (protocol-specific format)
    func handleNak(data: Data)

    /// Pause the transfer (if supported)
    func pause()

    /// Resume a paused transfer
    func resume()

    /// Cancel the transfer
    func cancel()

    // MARK: - Receiver Side

    /// Handle incoming data from the peer
    /// - Parameter data: Incoming frame data
    /// - Returns: true if the data was consumed by this protocol, false otherwise
    @discardableResult
    func handleIncomingData(_ data: Data) -> Bool

    /// Accept an incoming transfer request
    func acceptTransfer()

    /// Reject an incoming transfer request
    /// - Parameter reason: Human-readable rejection reason
    func rejectTransfer(reason: String)

    // MARK: - Protocol Detection

    /// Check if data appears to be from this protocol
    /// - Parameter data: Incoming data to check
    /// - Returns: true if this looks like data from this protocol
    static func canHandle(data: Data) -> Bool
}

// MARK: - Default Implementations

extension FileTransferProtocol {
    /// Default progress calculation
    var progress: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(1.0, Double(bytesTransferred) / Double(totalBytes))
    }
}

// MARK: - Protocol Errors

/// Errors that can occur during file transfer
enum FileTransferError: Error, LocalizedError, Sendable {
    case notConnected
    case protocolNotSupported
    case invalidState(expected: String, actual: String)
    case transferRejected(reason: String)
    case checksumMismatch
    case timeout
    case maxRetriesExceeded
    case cancelled
    case peerCancelled
    case invalidData(reason: String)
    case fileTooLarge(maxSize: Int)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to peer"
        case .protocolNotSupported:
            return "Transfer protocol not supported by peer"
        case .invalidState(let expected, let actual):
            return "Invalid state: expected \(expected), got \(actual)"
        case .transferRejected(let reason):
            return "Transfer rejected: \(reason)"
        case .checksumMismatch:
            return "Checksum mismatch - data corrupted"
        case .timeout:
            return "Transfer timed out waiting for response"
        case .maxRetriesExceeded:
            return "Maximum retries exceeded"
        case .cancelled:
            return "Transfer cancelled"
        case .peerCancelled:
            return "Transfer cancelled by peer"
        case .invalidData(let reason):
            return "Invalid data: \(reason)"
        case .fileTooLarge(let maxSize):
            return "File too large (max \(maxSize) bytes)"
        }
    }
}
