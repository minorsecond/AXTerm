//
//  TransferProtocolRegistry.swift
//  AXTerm
//
//  Registry for creating and detecting file transfer protocols.
//  Provides factory methods and protocol detection from incoming data.
//

import Foundation

// MARK: - Transfer Protocol Registry

/// Singleton registry for file transfer protocol creation and detection
final class TransferProtocolRegistry: @unchecked Sendable {
    /// Shared instance
    static let shared = TransferProtocolRegistry()

    /// Registered protocol types in detection priority order
    private let registeredProtocols: [TransferProtocolType] = [
        .axdp,      // Check AXDP first (modern protocol)
        .yapp,      // Then YAPP (common legacy)
        .sevenPlus, // Then 7plus (ASCII encoding)
        .rawBinary  // Raw binary last (minimal detection)
    ]

    private init() {}

    // MARK: - Protocol Creation

    /// Create a protocol instance for the specified type
    /// - Parameter type: The protocol type to create
    /// - Returns: A new protocol instance
    func createProtocol(type: TransferProtocolType) -> FileTransferProtocol {
        switch type {
        case .axdp:
            return AXDPTransferProtocol()
        case .yapp:
            return YAPPProtocol()
        case .sevenPlus:
            return SevenPlusProtocol()
        case .rawBinary:
            return RawBinaryProtocol()
        }
    }

    // MARK: - Protocol Detection

    /// Detect the protocol type from incoming data
    /// - Parameter data: Incoming frame data
    /// - Returns: Detected protocol type, or nil if unknown
    func detectProtocol(from data: Data) -> TransferProtocolType? {
        // Check each registered protocol in order
        for protocolType in registeredProtocols {
            switch protocolType {
            case .axdp:
                if AXDPTransferProtocol.canHandle(data: data) {
                    return .axdp
                }
            case .yapp:
                if YAPPProtocol.canHandle(data: data) {
                    return .yapp
                }
            case .sevenPlus:
                if SevenPlusProtocol.canHandle(data: data) {
                    return .sevenPlus
                }
            case .rawBinary:
                if RawBinaryProtocol.canHandle(data: data) {
                    return .rawBinary
                }
            }
        }
        return nil
    }

    /// Detect and create a protocol handler for incoming data
    /// - Parameter data: Incoming frame data
    /// - Returns: A protocol instance configured to handle the data, or nil
    func detectAndCreate(from data: Data) -> FileTransferProtocol? {
        guard let type = detectProtocol(from: data) else {
            return nil
        }
        return createProtocol(type: type)
    }

    // MARK: - Protocol Availability

    /// Get available protocols for a peer based on their capabilities
    /// - Parameters:
    ///   - callsign: Peer's callsign
    ///   - hasAXDP: Whether the peer supports AXDP
    ///   - isConnected: Whether we have an established AX.25 connected session
    /// - Returns: List of available protocol types, sorted by preference
    func availableProtocols(
        for callsign: String,
        hasAXDP: Bool,
        isConnected: Bool
    ) -> [TransferProtocolType] {
        var available: [TransferProtocolType] = []

        // AXDP is always preferred if peer supports it
        if hasAXDP {
            available.append(.axdp)
        }

        // Connected-mode protocols require an established session
        if isConnected {
            available.append(.yapp)
            available.append(.sevenPlus)
            // Note: Raw Binary is intentionally excluded from sending options
            // because it has no application-level ACKs - it's effectively pointless
            // for sending. It's kept in the codebase for receive-only support.
        }

        // If no AXDP and not connected, AXDP over UI frames is still possible
        // but not recommended for file transfers without reliability
        if !hasAXDP && !isConnected {
            // No reliable transfer options available
            // Could add .axdp here but UI-mode file transfers are unreliable
        }

        return available
    }

    /// Get the recommended protocol for a peer
    /// - Parameters:
    ///   - callsign: Peer's callsign
    ///   - hasAXDP: Whether the peer supports AXDP
    ///   - isConnected: Whether we have an established AX.25 connected session
    /// - Returns: Recommended protocol type, or nil if no suitable protocol
    func recommendedProtocol(
        for callsign: String,
        hasAXDP: Bool,
        isConnected: Bool
    ) -> TransferProtocolType? {
        let available = availableProtocols(for: callsign, hasAXDP: hasAXDP, isConnected: isConnected)
        return available.first
    }

    // MARK: - Protocol Info

    /// Get display information for all protocols
    /// - Returns: Array of protocol info for UI display
    func allProtocolInfo() -> [(type: TransferProtocolType, name: String, description: String)] {
        TransferProtocolType.allCases.map { type in
            (type: type, name: type.displayName, description: type.shortDescription)
        }
    }
}

// MARK: - AXDP Transfer Protocol Adapter

/// Adapter to wrap existing AXDP implementation in FileTransferProtocol interface
final class AXDPTransferProtocol: FileTransferProtocol {
    let protocolType: TransferProtocolType = .axdp

    weak var delegate: FileTransferProtocolDelegate?

    private(set) var state: TransferProtocolState = .idle
    private(set) var bytesTransferred: Int = 0
    private(set) var totalBytes: Int = 0

    // Transfer state
    private var fileName: String = ""
    private var fileData: Data = Data()
    private var receivedData: Data = Data()
    private var receivedMetadata: TransferFileMetadata?

    static func canHandle(data: Data) -> Bool {
        // AXDP messages start with "AXT1" magic
        guard data.count >= 4 else { return false }
        let magic = String(data: data.prefix(4), encoding: .ascii)
        return magic == "AXT1"
    }

    func startSending(fileName: String, fileData: Data) throws {
        self.fileName = fileName
        self.fileData = fileData
        self.totalBytes = fileData.count
        self.bytesTransferred = 0

        state = .waitingForAccept
        delegate?.transferProtocol(self, stateChanged: state)

        // The actual AXDP sending is handled by SessionCoordinator's existing logic
        // This adapter mainly provides the unified interface
    }

    func handleAck(data: Data) {
        // AXDP handles this through SACK bitmaps in the message flow
    }

    func handleNak(data: Data) {
        // AXDP handles this through the message flow
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
        }
    }

    func cancel() {
        state = .cancelled
        delegate?.transferProtocol(self, stateChanged: state)
        delegate?.transferProtocol(self, didComplete: false, error: "Cancelled by user")
    }

    func handleIncomingData(_ data: Data) -> Bool {
        guard Self.canHandle(data: data) else { return false }
        // AXDP incoming data is handled by SessionCoordinator
        // This is a placeholder for the unified interface
        return true
    }

    func acceptTransfer() {
        if state == .waitingForAccept {
            state = .transferring
            delegate?.transferProtocol(self, stateChanged: state)
        }
    }

    func rejectTransfer(reason: String) {
        state = .cancelled
        delegate?.transferProtocol(self, stateChanged: state)
    }
}
