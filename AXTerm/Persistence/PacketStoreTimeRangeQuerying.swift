//
//  PacketStoreTimeRangeQuerying.swift
//  AXTerm
//
//  Created by AXTerm on 2026-10-02.
//

import Foundation

nonisolated protocol PacketStoreTimeRangeQuerying: Sendable {
    func loadPackets(in timeframe: DateInterval) throws -> [Packet]
    /// Frames this station transmitted in the window.
    func loadTransmittedPackets(in timeframe: DateInterval) throws -> [Packet]
}

extension PacketStoreTimeRangeQuerying {
    func loadTransmittedPackets(in timeframe: DateInterval) throws -> [Packet] { [] }
}
