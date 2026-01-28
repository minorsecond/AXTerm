//
//  SQLitePacketStoreTests.swift
//  AXTermTests
//
//  Created by Ross Wardrup on 2/1/26.
//

import XCTest
import GRDB
@testable import AXTerm

final class SQLitePacketStoreTests: XCTestCase {
    func testRoundTripOrderingAndPinned() throws {
        let store = try makeStore()
        let first = Packet(
            timestamp: Date(timeIntervalSince1970: 10),
            from: AX25Address(call: "CALL1"),
            to: AX25Address(call: "DEST"),
            frameType: .ui,
            control: 0x03,
            info: Data([0x41]),
            rawAx25: Data([0x01])
        )
        let second = Packet(
            timestamp: Date(timeIntervalSince1970: 20),
            from: AX25Address(call: "CALL2"),
            to: AX25Address(call: "DEST"),
            frameType: .i,
            control: 0x00,
            info: Data([0x42]),
            rawAx25: Data([0x02])
        )
        try store.save(first)
        try store.save(second)
        try store.setPinned(packetId: second.id, pinned: true)

        let recent = try store.loadRecent(limit: 10)
        XCTAssertEqual(recent.map(\.id), [second.id, first.id])
        XCTAssertEqual(recent.first?.pinned, true)
    }

    func testPruneRemovesOldest() throws {
        let store = try makeStore()
        let packets = (0..<6).map { index in
            Packet(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                from: AX25Address(call: "CALL\(index)"),
                to: AX25Address(call: "DEST"),
                frameType: .u,
                control: 0x13,
                info: Data([UInt8(index)]),
                rawAx25: Data([UInt8(index)])
            )
        }
        for packet in packets {
            try store.save(packet)
        }
        try store.pruneIfNeeded(retentionLimit: 3)
        let remaining = try store.loadRecent(limit: 10)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertFalse(remaining.contains(where: { $0.id == packets[0].id }))
        XCTAssertTrue(remaining.contains(where: { $0.id == packets[5].id }))
    }

    func testPersistsAllFrameTypes() throws {
        let store = try makeStore()
        let frames: [FrameType] = [.ui, .i, .s, .u]
        for frame in frames {
            let packet = Packet(
                timestamp: Date(),
                from: AX25Address(call: "CALL"),
                to: AX25Address(call: "DEST"),
                frameType: frame,
                control: 0x03,
                info: Data([0x41]),
                rawAx25: Data([0x01])
            )
            try store.save(packet)
        }

        let records = try store.loadRecent(limit: 10)
        let types = Set(records.map(\.frameType))
        XCTAssertEqual(types, Set(frames.map(\.rawValue)))
    }

    private func makeStore() throws -> SQLitePacketStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLitePacketStore(dbQueue: queue)
    }
}
