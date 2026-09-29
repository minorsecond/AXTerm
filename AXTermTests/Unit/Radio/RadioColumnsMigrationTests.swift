import XCTest
import GRDB
@testable import AXTerm

/// Migration v30: the radio on the rows a radio makes.
///
/// Every row written before the station had several radios belonged to the
/// one it had, so the columns arrive with `RadioID.primary` as their default
/// and old rows read back attributed to it. A serial or Bluetooth frame,
/// which has no TCP endpoint, stops borrowing the settings' one.
final class RadioColumnsMigrationTests: XCTestCase {

    /// A database as it stood before v30, with one row in each table the
    /// migration touches.
    ///
    /// A fresh database migrated to v29 by this build already carries the
    /// radio columns — the table definitions include them — so the fixture
    /// removes them again to stand where a database from an older build
    /// stands. That is the path v30's guarded `ALTER`s exist for.
    private func makeV29Queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue, upTo: "createRemoteBBSMailbox")
        try queue.write { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_packets_radio_receivedAt")
            for (table, column) in [("packets", "radioID"), ("packets", "kissPortNibble"),
                                    ("packets", "linkDescription"),
                                    ("terminal_sessions", "radioID"), ("bbs_calls", "radioID")] {
                try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN \(column)")
            }
            try db.execute(sql: """
                INSERT INTO terminal_sessions (id, remote, remoteBase, startedAt, outcome)
                VALUES ('11111111-1111-1111-1111-111111111111', 'DRLBBS', 'DRLBBS', ?, 'closed')
                """, arguments: [Date(timeIntervalSince1970: 1000)])
            try db.execute(sql: """
                INSERT INTO bbs_calls (callsign, connectedAt, actions, endedUnexpectedly)
                VALUES ('W0ARP', ?, '', 0)
                """, arguments: [Date(timeIntervalSince1970: 2000)])
        }
        return queue
    }

    private func columns(_ queue: DatabaseQueue, _ table: String) throws -> Set<String> {
        try queue.read { db in Set(try db.columns(in: table).map(\.name)) }
    }

    // MARK: - The migration

    func testOldRowsAreAttributedToThePrimaryRadio() throws {
        let queue = try makeV29Queue()
        XCTAssertFalse(try columns(queue, "packets").contains("radioID"), "fixture predates v30")

        try DatabaseManager.migrator.migrate(queue)

        XCTAssertTrue(try columns(queue, "packets").isSuperset(of: ["radioID", "kissPortNibble", "linkDescription"]))
        XCTAssertTrue(try columns(queue, "terminal_sessions").contains("radioID"))
        XCTAssertTrue(try columns(queue, "bbs_calls").contains("radioID"))

        let sessions = try SQLiteTerminalSessionStore(dbQueue: queue).sessions()
        XCTAssertEqual(sessions.map(\.radioID), [.primary])
        let calls = try SQLiteBBSMessageStore(dbQueue: queue).recentCalls(limit: 10)
        XCTAssertEqual(calls.map(\.radioID), [.primary])
        XCTAssertEqual(RadioID.primary.rawValue, "radio-primary", "the default the migration wrote")
    }

    func testTheMigrationIsIdempotentOnAFreshDatabase() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        try DatabaseManager.migrator.migrate(queue)
        XCTAssertTrue(try columns(queue, "packets").contains("radioID"))
    }

    // MARK: - Packets

    private func packet(radio: RadioID?, endpoint: KISSEndpoint?, port: UInt8 = 0, link: String? = nil) -> Packet {
        Packet(timestamp: Date(timeIntervalSince1970: 10),
               from: AX25Address(call: "K0NTS", ssid: 1), to: AX25Address(call: "TEST", ssid: 7),
               frameType: .ui, control: 0x03, info: Data([0x41]), rawAx25: Data([0x01, 0x02]),
               kissEndpoint: endpoint, radioID: radio, kissPort: port, linkDescription: link)
    }

    /// A serial frame has no TCP endpoint and says so — no borrowed address.
    func testASerialPacketRoundTripsWithoutATCPEndpoint() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let store = SQLitePacketStore(dbQueue: queue)
        let ic705 = RadioID(rawValue: "ic705")

        try store.save(packet(radio: ic705, endpoint: nil, port: 1, link: "/dev/cu.usbserial-1420"))

        let back = try store.loadRecent(limit: 1).map { $0.toPacket() }
        XCTAssertEqual(back.count, 1)
        XCTAssertNil(back.first?.kissEndpoint)
        XCTAssertEqual(back.first?.radioID, ic705)
        XCTAssertEqual(back.first?.kissPort, 1)
        XCTAssertEqual(back.first?.linkDescription, "/dev/cu.usbserial-1420")
    }

    /// A TCP frame keeps its endpoint, as it always did.
    func testATCPPacketKeepsItsEndpoint() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let store = SQLitePacketStore(dbQueue: queue)
        let endpoint = KISSEndpoint(host: "192.168.3.218", port: 8001)!

        try store.save(packet(radio: .primary, endpoint: endpoint))

        let back = try store.loadRecent(limit: 1).map { $0.toPacket() }
        XCTAssertEqual(back.first?.kissEndpoint, endpoint)
        XCTAssertEqual(back.first?.radioID, .primary)
    }

    /// A frame with no radio at all — a synthetic one — is filed under the
    /// primary rather than refused.
    func testAPacketWithNoRadioIsFiledUnderThePrimary() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let store = SQLitePacketStore(dbQueue: queue)
        try store.save(packet(radio: nil, endpoint: nil))
        XCTAssertEqual(try store.loadRecent(limit: 1).first?.toPacket().radioID, .primary)
    }

    // MARK: - Sessions and calls

    func testATerminalSessionRemembersItsRadio() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let store = SQLiteTerminalSessionStore(dbQueue: queue)
        let ic705 = RadioID(rawValue: "ic705")
        try store.save(TerminalSession(remote: "DRLBBS", radioID: ic705, startedAt: Date(timeIntervalSince1970: 5)))
        XCTAssertEqual(try store.sessions().first?.radioID, ic705)
    }

    func testAMailboxCallRemembersItsRadio() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let store = SQLiteBBSMessageStore(dbQueue: queue)
        let ic705 = RadioID(rawValue: "ic705")
        _ = try store.beginCall(callsign: "W0ARP", at: Date(timeIntervalSince1970: 5), radio: ic705)
        XCTAssertEqual(try store.recentCalls(limit: 1).first?.radioID, ic705)
    }
}
