import XCTest
import GRDB
@testable import AXTerm

final class SQLiteBBSMessageStoreTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func makeStore() throws -> SQLiteBBSMessageStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteBBSMessageStore(dbQueue: queue)
    }

    private func message(_ id: Int64, to: String = "K0EPI", from: String = "W0ARP") -> BBSMessage {
        BBSMessage(id: id, from: from, to: to, subject: "Subject",
                   body: "Body", receivedAt: t(0))
    }

    // MARK: - Messages

    func testStoreAndRead() throws {
        let store = try makeStore()
        try store.store(message(1))
        let all = try store.allMessages()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].from, "W0ARP")
        XCTAssertEqual(all[0].body, "Body")
    }

    /// The shell tells the caller the number before the row exists; the store
    /// has to honour it rather than assigning its own.
    func testStoreHonoursTheNumberTheShellPromised() throws {
        let store = try makeStore()
        try store.store(message(12))
        XCTAssertEqual(try store.allMessages().map(\.id), [12])
        XCTAssertEqual(try store.mailbox().nextID, 13)
    }

    func testEmptyMailboxStartsAtOne() throws {
        XCTAssertEqual(try makeStore().mailbox().nextID, 1)
    }

    /// If this ever fires, two callers were served at once and the listener's
    /// `.busy` rule failed — better an error than a silent renumber that
    /// leaves the caller quoting a number nobody else can see.
    func testReusingANumberIsAnError() throws {
        let store = try makeStore()
        try store.store(message(1))
        XCTAssertThrowsError(try store.store(message(1))) { error in
            XCTAssertEqual(error as? SQLiteBBSMessageStore.StoreError, .messageNumberTaken(1))
        }
    }

    func testCallsignsAreStoredUppercased() throws {
        let store = try makeStore()
        try store.store(BBSMessage(id: 1, from: "w0arp", to: "k0epi", subject: "s",
                                   body: "b", receivedAt: t(0)))
        let stored = try XCTUnwrap(try store.allMessages().first)
        XCTAssertEqual(stored.from, "W0ARP")
        XCTAssertEqual(stored.to, "K0EPI")
    }

    // MARK: - Kill and restore

    /// Mail is append-only (CLAUDE.md §7): a kill is a flag, not a delete.
    func testKillFlagsAndRestoreBringsItBack() throws {
        let store = try makeStore()
        try store.store(message(1))

        try store.kill(id: 1, at: t(60))
        XCTAssertEqual(try store.allMessages().count, 1, "the row must survive a kill")
        XCTAssertEqual(try store.allMessages()[0].killedAt, t(60))

        try store.restore(id: 1)
        XCTAssertNil(try store.allMessages()[0].killedAt)
    }

    func testPurgeIsTheOnlyThingThatActuallyDeletes() throws {
        let store = try makeStore()
        try store.store(message(1))
        try store.purge(id: 1)
        XCTAssertTrue(try store.allMessages().isEmpty)
    }

    // MARK: - Read flags

    func testMarkReadStamps() throws {
        let store = try makeStore()
        try store.store(message(1))
        try store.markRead(id: 1, at: t(60))
        XCTAssertEqual(try store.allMessages()[0].readAt, t(60))
    }

    /// The first read is the fact worth keeping.
    func testMarkReadNeverReStamps() throws {
        let store = try makeStore()
        try store.store(message(1))
        try store.markRead(id: 1, at: t(60))
        try store.markRead(id: 1, at: t(600))
        XCTAssertEqual(try store.allMessages()[0].readAt, t(60))
    }

    // MARK: - White pages

    func testLearnAndReadBack() throws {
        let store = try makeStore()
        try store.learnWhitePages(callsign: "w0arp", key: .name, value: " Bob ",
                                  source: .selfReported, at: t(0))
        let entry = try XCTUnwrap(try store.whitePages()["W0ARP"])
        XCTAssertEqual(entry.value(.name), "Bob")
        XCTAssertEqual(entry.fields[.name]?.source, .selfReported)
    }

    /// Recorded against the operator, not the radio they called from.
    func testDirectoryIsKeyedByBaseCallsign() throws {
        let store = try makeStore()
        try store.learnWhitePages(callsign: "W0ARP-10", key: .name, value: "Bob",
                                  source: .selfReported, at: t(0))
        XCTAssertNotNil(try store.whitePages()["W0ARP"])
    }

    /// The merge rule has to hold in the store, not only in the model: this is
    /// where two callers and a message header actually meet.
    func testInferenceDoesNotOverwriteTestimony() throws {
        let store = try makeStore()
        try store.learnWhitePages(callsign: "W0ARP", key: .name, value: "Bob",
                                  source: .selfReported, at: t(0))
        let changed = try store.learnWhitePages(callsign: "W0ARP", key: .name, value: "ROBERT",
                                                source: .observed, at: t(9_000))
        XCTAssertFalse(changed)
        XCTAssertEqual(try store.whitePages()["W0ARP"]?.value(.name), "Bob")
    }

    func testStrongerProvenanceReplaces() throws {
        let store = try makeStore()
        try store.learnWhitePages(callsign: "W0ARP", key: .homeBBS, value: "K0NTS",
                                  source: .observed, at: t(1_000))
        let changed = try store.learnWhitePages(callsign: "W0ARP", key: .homeBBS, value: "W0ARP",
                                                source: .selfReported, at: t(0))
        XCTAssertTrue(changed)
        XCTAssertEqual(try store.whitePages()["W0ARP"]?.value(.homeBBS), "W0ARP")
    }

    func testFieldsAreIndependent() throws {
        let store = try makeStore()
        try store.learnWhitePages(callsign: "W0ARP", key: .name, value: "Bob",
                                  source: .selfReported, at: t(0))
        try store.learnWhitePages(callsign: "W0ARP", key: .qth, value: "Denver",
                                  source: .selfReported, at: t(10))
        let entry = try XCTUnwrap(try store.whitePages()["W0ARP"])
        XCTAssertEqual(entry.value(.name), "Bob")
        XCTAssertEqual(entry.value(.qth), "Denver")
    }

    func testEmptyValuesAreNotLearned() throws {
        let store = try makeStore()
        XCTAssertFalse(try store.learnWhitePages(callsign: "W0ARP", key: .name, value: "   ",
                                                 source: .selfReported, at: t(0)))
        XCTAssertTrue(try store.whitePages().isEmpty)
    }

    /// The operator editing their own directory is not subject to the merge
    /// rule — that rule exists to stop inference overwriting testimony.
    func testSysopEditWinsUnconditionally() throws {
        let store = try makeStore()
        try store.learnWhitePages(callsign: "W0ARP", key: .name, value: "Bob",
                                  source: .selfReported, at: t(9_000))
        try store.setWhitePagesField(callsign: "W0ARP", key: .name, value: "Robert", at: t(0))
        XCTAssertEqual(try store.whitePages()["W0ARP"]?.value(.name), "Robert")
    }

    func testSysopClearingAFieldRemovesIt() throws {
        let store = try makeStore()
        try store.learnWhitePages(callsign: "W0ARP", key: .name, value: "Bob",
                                  source: .selfReported, at: t(0))
        try store.setWhitePagesField(callsign: "W0ARP", key: .name, value: "", at: t(10))
        XCTAssertNil(try store.whitePages()["W0ARP"]?.value(.name))
    }

    func testDeletingAnEntryRemovesEveryField() throws {
        let store = try makeStore()
        try store.learnWhitePages(callsign: "W0ARP", key: .name, value: "Bob",
                                  source: .selfReported, at: t(0))
        try store.learnWhitePages(callsign: "W0ARP", key: .qth, value: "Denver",
                                  source: .selfReported, at: t(0))
        try store.deleteWhitePages(callsign: "W0ARP")
        XCTAssertTrue(try store.whitePages().isEmpty)
    }

    // MARK: - File areas

    func testAreaRoundTrip() throws {
        let store = try makeStore()
        try store.saveFileArea(BBSFileArea(name: "net scripts", about: "Weekly nets",
                                           bookmark: Data([1, 2, 3])))
        let area = try XCTUnwrap(try store.fileAreas().first)
        XCTAssertEqual(area.name, "NETSCRIPTS")
        XCTAssertEqual(area.about, "Weekly nets")
        XCTAssertEqual(area.bookmark, Data([1, 2, 3]))
    }

    func testSavingAnAreaTwiceUpdatesIt() throws {
        let store = try makeStore()
        try store.saveFileArea(BBSFileArea(name: "OPS", about: "old"))
        try store.saveFileArea(BBSFileArea(name: "OPS", about: "new"))
        XCTAssertEqual(try store.fileAreas().count, 1)
        XCTAssertEqual(try store.fileAreas().first?.about, "new")
    }

    /// Otherwise stale text reappears if the operator later shares a folder
    /// that happens to have the same name.
    func testDeletingAnAreaTakesItsDescriptionsWithIt() throws {
        let store = try makeStore()
        try store.saveFileArea(BBSFileArea(name: "OPS"))
        try store.setFileDescription(area: "OPS", name: "net.txt", about: "Preamble")
        try store.deleteFileArea(name: "OPS")

        XCTAssertTrue(try store.fileAreas().isEmpty)
        XCTAssertTrue(try store.fileDescriptions().isEmpty)
    }

    func testDescriptionsAreKeyedByAreaAndName() throws {
        let store = try makeStore()
        try store.setFileDescription(area: "ops", name: "net.txt", about: "Preamble")
        XCTAssertEqual(try store.fileDescriptions()["OPS/net.txt"], "Preamble")
    }

    func testClearingADescriptionRemovesIt() throws {
        let store = try makeStore()
        try store.setFileDescription(area: "OPS", name: "net.txt", about: "Preamble")
        try store.setFileDescription(area: "OPS", name: "net.txt", about: "  ")
        XCTAssertTrue(try store.fileDescriptions().isEmpty)
    }

    // MARK: - Last visit

    /// Drives `FN`. Must mean "the call before this one", never "this one".
    func testLastVisitIgnoresTheCallInProgress() throws {
        let store = try makeStore()
        let earlier = try store.beginCall(callsign: "W0ARP", at: t(0))
        try store.endCall(id: earlier, at: t(60), unexpected: false)
        let current = try store.beginCall(callsign: "W0ARP", at: t(9_000))

        XCTAssertEqual(try store.lastVisit(callsign: "W0ARP", excluding: current), t(0))
    }

    func testFirstCallHasNoLastVisit() throws {
        let store = try makeStore()
        let current = try store.beginCall(callsign: "W0ARP", at: t(0))
        XCTAssertNil(try store.lastVisit(callsign: "W0ARP", excluding: current))
    }

    func testLastVisitIsPerCallsign() throws {
        let store = try makeStore()
        _ = try store.beginCall(callsign: "K0NTS", at: t(0))
        let current = try store.beginCall(callsign: "W0ARP", at: t(9_000))
        XCTAssertNil(try store.lastVisit(callsign: "W0ARP", excluding: current))
    }

    // MARK: - Calls

    func testCallIsLoggedWithItsActions() throws {
        let store = try makeStore()
        let id = try store.beginCall(callsign: "w0arp", at: t(0))
        try store.appendAction(callId: id, action: "read 7")
        try store.appendAction(callId: id, action: "left mail for K0EPI")
        try store.endCall(id: id, at: t(130), unexpected: false)

        let call = try XCTUnwrap(try store.recentCalls(limit: 10).first)
        XCTAssertEqual(call.callsign, "W0ARP")
        XCTAssertEqual(call.actions, ["read 7", "left mail for K0EPI"])
        XCTAssertEqual(call.duration, 130)
        XCTAssertFalse(call.endedUnexpectedly)
        XCTAssertFalse(call.isLive)
    }

    func testACallWithNoActionsIsStillLogged() throws {
        let store = try makeStore()
        let id = try store.beginCall(callsign: "W0ARP", at: t(0))
        try store.endCall(id: id, at: t(20), unexpected: false)
        let call = try XCTUnwrap(try store.recentCalls(limit: 10).first)
        XCTAssertTrue(call.actions.isEmpty)
    }

    func testAnOpenCallReadsAsLive() throws {
        let store = try makeStore()
        _ = try store.beginCall(callsign: "W0ARP", at: t(0))
        XCTAssertTrue(try XCTUnwrap(try store.recentCalls(limit: 10).first).isLive)
    }

    func testEndCallDoesNotReopenAClosedOne() throws {
        let store = try makeStore()
        let id = try store.beginCall(callsign: "W0ARP", at: t(0))
        try store.endCall(id: id, at: t(20), unexpected: false)
        try store.endCall(id: id, at: t(900), unexpected: true)
        let call = try XCTUnwrap(try store.recentCalls(limit: 10).first)
        XCTAssertEqual(call.duration, 20)
        XCTAssertFalse(call.endedUnexpectedly)
    }

    /// A call left open by a crash ended when the app did, not now — stamping
    /// "now" would invent a caller who stayed connected for three days.
    func testOrphanedCallsCloseAtTheirConnectTime() throws {
        let store = try makeStore()
        _ = try store.beginCall(callsign: "W0ARP", at: t(0))
        try store.closeOrphanedCalls(at: t(300_000))

        let call = try XCTUnwrap(try store.recentCalls(limit: 10).first)
        XCTAssertEqual(call.disconnectedAt, t(0))
        XCTAssertTrue(call.endedUnexpectedly)
        XCTAssertFalse(call.isLive)
    }

    func testRecentCallsAreNewestFirst() throws {
        let store = try makeStore()
        _ = try store.beginCall(callsign: "FIRST", at: t(0))
        _ = try store.beginCall(callsign: "SECOND", at: t(60))
        XCTAssertEqual(try store.recentCalls(limit: 10).map(\.callsign), ["SECOND", "FIRST"])
    }
}
