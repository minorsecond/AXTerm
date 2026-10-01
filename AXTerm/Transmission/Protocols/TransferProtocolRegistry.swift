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
nonisolated final class TransferProtocolRegistry: @unchecked Sendable {
    /// Shared instance
    static let shared = TransferProtocolRegistry()

    /// 7plus is temporarily disabled until prioritized for stabilization.
    /// TODO(7plus): Re-enable when protocol implementation is reviewed and scheduled.
    private let sevenPlusEnabled = false

    /// Raw Binary is kept for reference but not exposed to users.
    /// TODO(raw-binary): Re-enable when user-facing UX and reliability story are defined.
    private let rawBinaryEnabled = false

    /// Registered protocol types in detection priority order
    private var registeredProtocols: [TransferProtocolType] {
        var protocols: [TransferProtocolType] = [
            .axdp,     // Check AXDP first (modern protocol)
            .yapp      // Then YAPP (common legacy)
        ]
        if sevenPlusEnabled {
            protocols.insert(.sevenPlus, at: 2)
        }
        if rawBinaryEnabled {
            protocols.append(.rawBinary)
        }
        return protocols
    }

    private init() {}

    // MARK: - Protocol Creation

    /// Create a protocol instance for the specified type
    /// - Parameter type: The protocol type to create
    /// - Returns: A new protocol instance, or nil for AXDP
    ///
    /// AXDP has no instance to hand out. Its sender and receiver are
    /// `SessionCoordinator`'s own (`startTransfer` and the FILE_META/ACK
    /// handlers), and an adapter that only changed state here once left a
    /// mailbox caller waiting for a file that was never sent.
    func createProtocol(type: TransferProtocolType) -> FileTransferProtocol? {
        switch type {
        case .axdp:
            return nil
        case .yapp:
            return YAPPProtocol()
        case .sevenPlus:
            return SevenPlusProtocol()
        case .rawBinary:
            return RawBinaryProtocol()
        case .text:
            // Text downloads and captures are read out of the terminal's
            // lines (`ReceivedTextRecorder`); there is no driver to hand out.
            return nil
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
                if AXDP.hasMagic(data) {
                    return .axdp
                }
            case .yapp:
                if YAPPProtocol.canHandle(data: data) {
                    return .yapp
                }
            case .sevenPlus:
                if sevenPlusEnabled, SevenPlusProtocol.canHandle(data: data) {
                    return .sevenPlus
                }
            case .rawBinary:
                if rawBinaryEnabled, RawBinaryProtocol.canHandle(data: data) {
                    return .rawBinary
                }
            case .text:
                // Never registered: text is not detected from a packet.
                break
        }
        }
        return nil
    }

    /// Detect and create a protocol handler for incoming data
    /// - Parameter data: Incoming frame data
    /// - Returns: A protocol instance configured to handle the data, or nil
    ///   when the data is unrecognized or is AXDP (see `createProtocol`)
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
            if sevenPlusEnabled {
                available.append(.sevenPlus)
            }
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
