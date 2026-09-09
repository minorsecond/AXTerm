import XCTest
import GRDB
@testable import AXTerm

final class APRSMessageStoreTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func makeStore() throws -> SQLiteAPRSMessageStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteAPRSMessageStore(dbQueue: queue)
    }

    private func incoming(_ id: String, from peer: String, text: String,
                          number: String? = nil, direct: Bool = false) -> APRSMessageRecord {
        APRSMessageRecord(id: id, direction: .incoming, kind: .message,
                          localCall: "K0EPI-7", peer: peer, text: text, number: number,
                          radioID: "radio-primary", viaDirect: direct,
                          createdAt: t(0), state: .received)
    }

    private func outgoing(_ id: String, to peer: String, number: String?,
                          state: APRSMessageRecord.State,
                          nextRetryAt: Date? = nil) -> APRSMessageRecord {
        APRSMessageRecord(id: id, direction: .outgoing, kind: .message,
                          localCall: "K0EPI-7", peer: peer, text: "hi", number: number,
                          radioID: "radio-primary", createdAt: t(0), state: state,
                          attempts: 1, nextRetryAt: nextRetryAt)
    }

    func testUpsertAndReadBack() throws {
        let store = try makeStore()
        try store.upsert(incoming("a", from: "W0ARP", text: "hello", direct: true))
        let all = try store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].text, "hello")
        XCTAssertEqual(all[0].peer, "W0ARP")
        XCTAssertTrue(all[0].viaDirect)
        XCTAssertFalse(all[0].isRead)
    }

    func testUpsertReplacesById() throws {
        let store = try makeStore()
        try store.upsert(outgoing("x", to: "W0ARP", number: "1", state: .sent))
        var r = try XCTUnwrap(try store.all().first)
        r.state = .acked
        r.ackedAt = t(5)
        try store.upsert(r)
        let all = try store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].state, .acked)
        XCTAssertEqual(all[0].ackedAt, t(5))
    }

    func testMarkThreadReadOnlyAffectsIncoming() throws {
        let store = try makeStore()
        try store.upsert(incoming("a", from: "W0ARP", text: "one"))
        try store.upsert(incoming("b", from: "W0ARP", text: "two"))
        try store.upsert(outgoing("c", to: "W0ARP", number: nil, state: .sent))
        try store.markThreadRead(peer: "W0ARP", at: t(10))
        let byId = Dictionary(uniqueKeysWithValues: try store.all().map { ($0.id, $0) })
        XCTAssertTrue(byId["a"]!.isRead)
        XCTAssertTrue(byId["b"]!.isRead)
        XCTAssertFalse(byId["c"]!.isRead)   // outgoing untouched
    }

    func testOutgoingLookupForAckMatching() throws {
        let store = try makeStore()
        try store.upsert(outgoing("x", to: "W0ARP", number: "42", state: .sent))
        try store.upsert(outgoing("y", to: "N0CALL", number: "42", state: .sent))
        let hit = try store.outgoing(peer: "W0ARP", number: "42")
        XCTAssertEqual(hit?.id, "x")
        XCTAssertNil(try store.outgoing(peer: "W0ARP", number: "99"))
    }

    func testDuePendingSelectsOverdueSentOnly() throws {
        let store = try makeStore()
        try store.upsert(outgoing("due", to: "W0ARP", number: "1", state: .sent, nextRetryAt: t(5)))
        try store.upsert(outgoing("later", to: "W0ARP", number: "2", state: .sent, nextRetryAt: t(50)))
        try store.upsert(outgoing("acked", to: "W0ARP", number: "3", state: .acked, nextRetryAt: t(5)))
        let due = try store.duePending(now: t(10))
        XCTAssertEqual(due.map(\.id), ["due"])
    }

    func testDelete() throws {
        let store = try makeStore()
        try store.upsert(incoming("a", from: "W0ARP", text: "hello"))
        try store.delete(id: "a")
        XCTAssertTrue(try store.all().isEmpty)
    }
}
