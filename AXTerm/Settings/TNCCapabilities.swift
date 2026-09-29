//
//  TNCCapabilities.swift
//  AXTerm
//
//  Capability model for TNC connection modes.
//  Gates which link-layer settings AXTerm can honestly control.
//

import Foundation

/// The operating mode of the connected TNC.
/// In KISS mode, AXTerm owns the AX.25 link layer.
/// In host mode, the TNC manages it internally.
nonisolated enum TNCMode: String, Codable, Equatable, CaseIterable {
    case kiss
    case host
    case unknown
}

/// Describes what link-layer tuning capabilities are available
/// for the current TNC connection mode.
nonisolated struct TNCCapabilities: Codable, Equatable {
    var mode: TNCMode = .kiss
    var supportsLinkTuning: Bool = true
    var supportsModemTuning: Bool = false
    var supportsCustomCommands: Bool = false
}
