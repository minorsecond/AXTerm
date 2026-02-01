//
//  PacketPersistenceControlFieldTests.swift
//  AXTermTests
//
//  Tests for AX.25 Control Field persistence in the packets table.
//  Written TDD-style: these tests must fail initially until production code is implemented.
//

import XCTest
import GRDB
@testable import AXTerm

final class PacketPersistenceControlFieldTests: XCTestCase {

    // MARK: - I-Frame Persistence

    /// Test that I-frame control fields are persisted correctly
    /// Note: For I-frames with 2 control bytes, we use controlByte1 parameter
    func testControlFieldsPersistedForIFrame() throws {
        let store = try makeStore()
        let queue = try makeDBQueue()
        let endpoint = try makeEndpoint()

        // Create an I-frame packet with both control bytes
        // I-frame with N(S)=2, P/F=1, N(R)=3
        // ctl0: 0x04 (N(S)=2 in bits 1-3, bit 0=0)
        // ctl1: 0x70 (N(R)=3 in bits 5-7, P/F=1 in bit 4)
        let packet = Packet(
            timestamp: Date(timeIntervalSince1970: 100),
            from: AX25Address(call: "TEST1"),
            to: AX25Address(call: "TEST2"),
            frameType: .i,
            control: 0x04,
            controlByte1: 0x70,
            pid: 0xF0,
            info: Data([0x41, 0x42]),
            rawAx25: Data([0x01, 0x02, 0x03]),
            kissEndpoint: endpoint
        )

        try store.save(packet)

        // Fetch the record directly to verify control field columns
        let record = try queue.read { db in
            try PacketRecord.fetchOne(db, key: packet.id)
        }

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.ax25FrameClass, "I")
        XCTAssertNil(record?.ax25SType)
        XCTAssertNil(record?.ax25UType)
        XCTAssertEqual(record?.ax25Ns, 2)
        XCTAssertEqual(record?.ax25Nr, 3)
        XCTAssertEqual(record?.ax25Pf, 1)
        XCTAssertEqual(record?.ax25Ctl0, 0x04)
        XCTAssertEqual(record?.ax25Ctl1, 0x70)
        XCTAssertEqual(record?.ax25IsExtended, 0)
    }

    // MARK: - S-Frame Persistence

    /// Test that S-frame control fields are persisted correctly
    func testControlFieldsPersistedForSFrame() throws {
        let store = try makeStore()
        let queue = try makeDBQueue()
        let endpoint = try makeEndpoint()

        // Create an S-frame RR packet
        // S-frame RR with N(R)=5, P/F=1
        // ctl0: 0xB1 (N(R)=5 in bits 5-7, P/F=1 in bit 4, RR=0b00 in bits 2-3, 0b01 in bits 0-1)
        let packet = Packet(
            timestamp: Date(timeIntervalSince1970: 200),
            from: AX25Address(call: "SRC"),
            to: AX25Address(call: "DST"),
            frameType: .s,
            control: 0xB1,
            pid: nil,
            info: Data(),
            rawAx25: Data([0x01]),
            kissEndpoint: endpoint
        )

        try store.save(packet)

        // Fetch the record directly to verify control field columns
        let record = try queue.read { db in
            try PacketRecord.fetchOne(db, key: packet.id)
        }

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.ax25FrameClass, "S")
        XCTAssertEqual(record?.ax25SType, "RR")
        XCTAssertNil(record?.ax25UType)
        XCTAssertNil(record?.ax25Ns)  // S-frames don't have N(S)
        XCTAssertEqual(record?.ax25Nr, 5)
        XCTAssertEqual(record?.ax25Pf, 1)
        XCTAssertEqual(record?.ax25Ctl0, 0xB1)
        XCTAssertNil(record?.ax25Ctl1)  // S-frames are single byte (modulo-8)
        XCTAssertEqual(record?.ax25IsExtended, 0)
    }

    /// Test S-frame REJ persistence
    func testControlFieldsPersistedForSFrameREJ() throws {
        let store = try makeStore()
        let queue = try makeDBQueue()
        let endpoint = try makeEndpoint()

        // S-frame REJ with N(R)=2, P/F=0
        // ctl0: 0x49 (N(R)=2 in bits 5-7, P/F=0, REJ=0b10 in bits 2-3, S-frame=0b01)
        let packet = Packet(
            timestamp: Date(timeIntervalSince1970: 300),
            from: AX25Address(call: "SRC"),
            to: AX25Address(call: "DST"),
            frameType: .s,
            control: 0x49,
            pid: nil,
            info: Data(),
            rawAx25: Data([0x01]),
            kissEndpoint: endpoint
        )

        try store.save(packet)

        let record = try queue.read { db in
            try PacketRecord.fetchOne(db, key: packet.id)
        }

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.ax25FrameClass, "S")
        XCTAssertEqual(record?.ax25SType, "REJ")
        XCTAssertEqual(record?.ax25Nr, 2)
        XCTAssertEqual(record?.ax25Pf, 0)
    }

    // MARK: - U-Frame Persistence

    /// Test that U-frame UI control fields are persisted correctly
    func testControlFieldsPersistedForUFrame() throws {
        let store = try makeStore()
        let queue = try makeDBQueue()
        let endpoint = try makeEndpoint()

        // U-frame UI with P/F=0
        // ctl0: 0x03
        let packet = Packet(
            timestamp: Date(timeIntervalSince1970: 400),
            from: AX25Address(call: "BEACON"),
            to: AX25Address(call: "ALL"),
            frameType: .ui,
            control: 0x03,
            pid: 0xF0,
            info: Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]), // "Hello"
            rawAx25: Data([0x01]),
            kissEndpoint: endpoint
        )

        try store.save(packet)

        let record = try queue.read { db in
            try PacketRecord.fetchOne(db, key: packet.id)
        }

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.ax25FrameClass, "U")
        XCTAssertNil(record?.ax25SType)
        XCTAssertEqual(record?.ax25UType, "UI")
        XCTAssertNil(record?.ax25Ns)  // U-frames don't have sequence numbers
        XCTAssertNil(record?.ax25Nr)
        XCTAssertEqual(record?.ax25Pf, 0)
        XCTAssertEqual(record?.ax25Ctl0, 0x03)
        XCTAssertNil(record?.ax25Ctl1)
        XCTAssertEqual(record?.ax25IsExtended, 0)
    }

    /// Test U-frame SABM persistence
    func testControlFieldsPersistedForUFrameSABM() throws {
        let store = try makeStore()
        let queue = try makeDBQueue()
        let endpoint = try makeEndpoint()

        // U-frame SABM with P/F=1
        // ctl0: 0x3F (SABM=0x2F | P/F=0x10)
        let packet = Packet(
            timestamp: Date(timeIntervalSince1970: 500),
            from: AX25Address(call: "CONN1"),
            to: AX25Address(call: "CONN2"),
            frameType: .u,
            control: 0x3F,
            pid: nil,
            info: Data(),
            rawAx25: Data([0x01]),
            kissEndpoint: endpoint
        )

        try store.save(packet)

        let record = try queue.read { db in
            try PacketRecord.fetchOne(db, key: packet.id)
        }

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.ax25FrameClass, "U")
        XCTAssertEqual(record?.ax25UType, "SABM")
        XCTAssertEqual(record?.ax25Pf, 1)
        XCTAssertEqual(record?.ax25Ctl0, 0x3F)
    }

    // MARK: - Unknown Frame Persistence

    /// Test that a U-frame with unknown subtype is persisted correctly.
    /// Note: 0xFF has bits 0-1 = 11, which is a U-frame pattern.
    /// The decoder correctly classifies it as U-frame with UNKNOWN subtype.
    func testControlFieldsPersistedForUnknownFrame() throws {
        let store = try makeStore()
        let queue = try makeDBQueue()
        let endpoint = try makeEndpoint()

        // 0xFF is a U-frame pattern (bits 0-1 = 11) with unknown subtype
        let packet = Packet(
            timestamp: Date(timeIntervalSince1970: 600),
            from: AX25Address(call: "SRC"),
            to: AX25Address(call: "DST"),
            frameType: .u,  // The decoder will classify 0xFF as U-frame
            control: 0xFF,
            pid: nil,
            info: Data(),
            rawAx25: Data([0x01]),
            kissEndpoint: endpoint
        )

        try store.save(packet)

        let record = try queue.read { db in
            try PacketRecord.fetchOne(db, key: packet.id)
        }

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.ax25FrameClass, "U")
        XCTAssertEqual(record?.ax25UType, "UNKNOWN")
        XCTAssertEqual(record?.ax25Ctl0, 0xFF)
    }

    // MARK: - Round-Trip Tests

    /// Test that control fields survive a save/load round trip
    func testControlFieldsRoundTrip() throws {
        let store = try makeStore()
        let endpoint = try makeEndpoint()

        // S-frame RR - simpler to test round-trip without controlByte1 complexity
        let original = Packet(
            timestamp: Date(timeIntervalSince1970: 700),
            from: AX25Address(call: "ROUND"),
            to: AX25Address(call: "TRIP"),
            frameType: .s,
            control: 0xD1,  // S-frame RR with N(R)=6, P/F=1
            pid: nil,
            info: Data(),
            rawAx25: Data([0x01]),
            kissEndpoint: endpoint
        )

        try store.save(original)
        let loadedRecord = try store.loadRecent(limit: 1).first

        XCTAssertNotNil(loadedRecord)

        // Convert PacketRecord to Packet to access controlFieldDecoded
        let loadedPacket = loadedRecord?.toPacket()
        XCTAssertEqual(loadedPacket?.controlFieldDecoded.frameClass, .S)
        XCTAssertEqual(loadedPacket?.controlFieldDecoded.sType, .RR)
        XCTAssertEqual(loadedPacket?.controlFieldDecoded.nr, 6)
        XCTAssertEqual(loadedPacket?.controlFieldDecoded.pf, 1)
    }

    // MARK: - Test Helpers

    private var testDBQueue: DatabaseQueue?

    private func makeDBQueue() throws -> DatabaseQueue {
        if let existing = testDBQueue {
            return existing
        }
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        testDBQueue = queue
        return queue
    }

    private func makeStore() throws -> SQLitePacketStore {
        let queue = try makeDBQueue()
        return SQLitePacketStore(dbQueue: queue)
    }

    private func makeEndpoint() throws -> KISSEndpoint {
        guard let endpoint = KISSEndpoint(host: "localhost", port: 8001) else {
            XCTFail("Expected valid KISS endpoint")
            throw TestError.invalidEndpoint
        }
        return endpoint
    }

    private enum TestError: Error {
        case invalidEndpoint
    }
}
