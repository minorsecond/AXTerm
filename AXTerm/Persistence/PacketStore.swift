//
//  PacketStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation

protocol PacketStore: Sendable {
    func save(_ packet: Packet) throws
    func loadRecent(limit: Int) throws -> [PacketRecord]
    func deleteAll() throws
    func setPinned(packetId: UUID, pinned: Bool) throws
    func pruneIfNeeded(retentionLimit: Int) throws
    func count() throws -> Int
}
