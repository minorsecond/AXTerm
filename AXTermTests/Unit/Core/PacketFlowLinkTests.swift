import GRDB
import XCTest
@testable import AXTerm

/// A connected exchange, read back as the exchange it was.
///
/// `packets` records frames and nothing else, so a conversation came back as
/// unrelated rows. `terminal_sessions` keeps only totals and
/// `outbound_message` knows our half, so neither could show it in order with
/// both directions and the retries visible as the separate frames they are.
final class PacketFlowLinkTests: XCTestCase {

    private func makeStore() throws -> SQLitePacketStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLitePacketStore(dbQueue: queue)
    }

    private func frame(_ direction: Packet.Direction, at offset: TimeInterval,
                       session: UUID?, message: UUID? = nil,
                       from: String, to: String) -> Packet {
        Packet(timestamp: Date(timeIntervalSince1970: 1_756_000_000 + offset),
               from: AX25Address(call: from), to: AX25Address(call: to),
               frameType: .i, control: 0x00, pid: 0xF0,
               info: Data("hello".utf8), rawAx25: Data([0x01, 0x02]),
               direction: direction, sessionId: session, messageId: message)
    }

    func testAConnectedExchangeComesBackInOrderWithBothDirections() throws {
        let store = try makeStore()
        let session = UUID()
        let other = UUID()

        try store.save(frame(.tx, at: 0, session: session, from: "K0EPI", to: "KB5YZB-7"))
        try store.save(frame(.rx, at: 1, session: session, from: "KB5YZB-7", to: "K0EPI"))
        try store.save(frame(.tx, at: 2, session: session, from: "K0EPI", to: "KB5YZB-7"))
        // Another conversation, and a beacon belonging to neither.
        try store.save(frame(.rx, at: 3, session: other, from: "W0NED", to: "K0EPI"))
        try store.save(frame(.tx, at: 4, session: nil, from: "K0EPI", to: "APZAXT"))

        let flow = try store.loadRecent(limit: 50)
            .filter { $0.sessionId == session.uuidString }
            .sorted { $0.receivedAt < $1.receivedAt }

        XCTAssertEqual(flow.count, 3, "the other session and the beacon stay out of it")
        XCTAssertEqual(flow.map(\.direction), ["tx", "rx", "tx"],
                       "an exchange is both halves, in the order they happened")
    }

    /// One message costs many frames and every retry is another frame
    /// against the same message. That is what makes the cost visible.
    func testEveryFrameAMessageCostIsFoundByItsMessageId() throws {
        let store = try makeStore()
        let message = UUID()
        let session = UUID()

        for attempt in 0..<3 {
            try store.save(frame(.tx, at: Double(attempt), session: session,
                                 message: message, from: "K0EPI", to: "KB5YZB-7"))
        }
        try store.save(frame(.rx, at: 9, session: session, from: "KB5YZB-7", to: "K0EPI"))

        let cost = try store.loadRecent(limit: 50).filter { $0.messageId == message.uuidString }
        XCTAssertEqual(cost.count, 3, "three transmissions to deliver one message")
    }

    /// Null on both is the normal case, not a gap: most traffic belongs to
    /// no session and no message.
    func testABeaconBelongsToNothingAndThatIsFine() throws {
        let store = try makeStore()
        try store.save(frame(.tx, at: 0, session: nil, from: "K0EPI", to: "APZAXT"))

        let stored = try XCTUnwrap(try store.loadRecent(limit: 10).first)
        XCTAssertNil(stored.sessionId)
        XCTAssertNil(stored.messageId)
        XCTAssertEqual(stored.direction, "tx")
    }

    /// A stored frame must come back saying which way it went and what it
    /// belonged to, or a flow loses its members leaving the database.
    func testTheLinksSurviveTheRoundTrip() throws {
        let store = try makeStore()
        let session = UUID()
        let message = UUID()
        try store.save(frame(.tx, at: 0, session: session, message: message,
                             from: "K0EPI", to: "KB5YZB-7"))

        let back = try XCTUnwrap(try store.loadRecent(limit: 10).first).toPacket()
        XCTAssertEqual(back.direction, .tx)
        XCTAssertEqual(back.sessionId, session)
        XCTAssertEqual(back.messageId, message)
    }

    /// Analytics count stations heard. Our own transmissions are in this
    /// table now and must not be counted as traffic from anyone.
    func testOurOwnTransmissionsAreNotCountedAsHeardTraffic() throws {
        let store = try makeStore()
        let window = DateInterval(start: Date(timeIntervalSince1970: 1_756_000_000 - 60),
                                  end: Date(timeIntervalSince1970: 1_756_000_000 + 60))
        try store.save(frame(.rx, at: 0, session: nil, from: "W0NED", to: "APRS"))
        try store.save(frame(.tx, at: 1, session: nil, from: "K0EPI", to: "APZAXT"))
        try store.save(frame(.tx, at: 2, session: nil, from: "K0EPI", to: "APZAXT"))

        let heard = try store.loadPackets(in: window)
        XCTAssertEqual(heard.count, 1, "three rows stored, one frame actually heard")
        XCTAssertEqual(heard.first?.from?.call, "W0NED")
    }
}
