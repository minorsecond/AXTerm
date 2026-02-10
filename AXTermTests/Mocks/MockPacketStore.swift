//
//  MockPacketStore.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation
@testable import AXTerm

final class MockPacketStore: PacketStore, @unchecked Sendable {
    private(set) var savedPackets: [Packet] = []
    private(set) var pinnedUpdates: [(UUID, Bool)] = []
    private(set) var deleteAllCalled = false
    private(set) var pruneCalls: [Int] = []
    var loadResult: [PacketRecord] = []

    func save(_ packet: Packet) throws {
        savedPackets.append(packet)
    }

    func loadRecent(limit: Int) throws -> [PacketRecord] {
        Array(loadResult.prefix(limit))
    }

    func deleteAll() throws {
        deleteAllCalled = true
    }

    func setPinned(packetId: UUID, pinned: Bool) throws {
        pinnedUpdates.append((packetId, pinned))
    }

    func pruneIfNeeded(retentionLimit: Int) throws {
        pruneCalls.append(retentionLimit)
    }

    func count() throws -> Int {
        savedPackets.count
    }
}
