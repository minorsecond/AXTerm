import XCTest
import GRDB
@testable import AXTerm

/// The map's node layer draws a directory node only when its operator's
/// record is in `CallsignLookupService.records`, and that dictionary starts
/// empty at every launch. So how the cache gets back into memory decides
/// whether the layer is on the map at launch or arrives over the following
/// minutes — which is what it did (field ask 2026-09-03: 150 of 170 node
/// operators sat in the local cache while the map drew a handful).
@MainActor
final class CallsignCachePreloadTests: XCTestCase {

    /// A remote that must never be reached: every assertion here is about
    /// the *local* cache, and a lookup leaking out to the network would
    /// make these pass for the wrong reason.
    final class ForbiddenDirectory: CallsignDirectory, @unchecked Sendable {
        let sourceName = "Forbidden"
        let requiresNetwork = true
        var callCount = 0
        func lookup(_ callsign: String) async throws -> CallsignRecord? {
            callCount += 1
            return nil
        }
    }

    private func makeStore() throws -> SQLiteWinlinkStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteWinlinkStore(dbQueue: queue)
    }

    private func cache(_ store: SQLiteWinlinkStore,
                       _ callsigns: [String]) throws {
        for call in callsigns {
            try store.saveCallsignRecord(CallsignDirectoryRecord(
                callsign: CallsignQuery.normalize(call),
                name: "Operator \(call)", gridSquare: "DM79",
                latitude: 39.7, longitude: -104.9,
                locality: nil, state: nil, country: nil,
                licenseClass: nil, expires: nil,
                source: "test", fetchedAt: Date()))
        }
    }

    // MARK: - The bulk read

    func testBulkReadAnswersManyCallsignsAtOnce() throws {
        let store = try makeStore()
        try cache(store, ["W9OTR", "KE0NCQ", "K0ZIA"])

        let found = try store.callsignRecords(
            callsigns: ["W9OTR", "KE0NCQ", "K0ZIA", "N0BODY"])

        XCTAssertEqual(Set(found.map(\.callsign)), ["W9OTR", "KE0NCQ", "K0ZIA"],
                       "a miss is the ordinary answer, not an error")
    }

    /// The directory names operators with SSIDs — `KE0NCQ-2` — and the
    /// cache is keyed by base callsign. A bulk read that skipped the
    /// normalisation the single read does would silently place nothing.
    func testBulkReadNormalisesSSIDsTheWayTheSingleReadDoes() throws {
        let store = try makeStore()
        try cache(store, ["KE0NCQ"])

        XCTAssertEqual(
            try store.callsignRecords(callsigns: ["KE0NCQ-2"]).map(\.callsign),
            ["KE0NCQ"])
    }

    func testBulkReadOfNothingAsksTheDatabaseNothing() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.callsignRecords(callsigns: []).isEmpty)
        XCTAssertTrue(try store.callsignRecords(callsigns: ["", "   "]).isEmpty)
    }

    // MARK: - Preload

    /// The fix itself: positions already in this app's cache reach memory
    /// in one step, with no network and no waiting.
    func testPreloadPlacesTheWholeDirectoryFromCacheWithoutTheNetwork() async throws {
        let store = try makeStore()
        let operators = (0..<120).map { "N\($0)AA" }
        try cache(store, operators)
        let remote = ForbiddenDirectory()
        let service = CallsignLookupService(
            store: store, remote: remote, isNetworkEnabled: true)

        service.preload(operators)

        XCTAssertEqual(service.records.count, 120)
        XCTAssertEqual(remote.callCount, 0,
                       "reading our own cache is not a fetch")
    }

    /// One query for the whole list, not one per name.
    ///
    /// The node directory names hundreds of operators, and asking about
    /// them one at a time is what made filling the layer expensive enough
    /// to be paced in the first place. Counted at the database rather than
    /// through the service's own bookkeeping, so the test measures what
    /// actually happens on disk.
    // async, like every other test here that builds a lookup service: a
    // MainActor-isolated class deallocated from a synchronous test body
    // aborts in its own deinit, which is this module's oldest trap.
    func testPreloadAsksTheDatabaseOnceForTheWholeList() async throws {
        let counter = StatementCounter()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { event in
                if "\(event)".contains("callsignDirectory") { counter.bump() }
            }
        }
        let queue = try DatabaseQueue(path: ":memory:", configuration: config)
        try DatabaseManager.migrator.migrate(queue)
        let store = SQLiteWinlinkStore(dbQueue: queue)
        let operators = (0..<50).map { "W\($0)BB" }
        try cache(store, operators)
        let service = CallsignLookupService(store: store, remote: ForbiddenDirectory())

        counter.reset()
        service.preload(operators)

        XCTAssertEqual(service.records.count, 50)
        XCTAssertEqual(counter.count, 1,
                       "fifty operators, one read — and so one publish")
    }

    /// Trace callbacks arrive on the database's own thread.
    final class StatementCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func bump() { lock.withLock { value += 1 } }
        func reset() { lock.withLock { value = 0 } }
    }

    /// A record resolved this session is the fresher of the two. Preload
    /// must not overwrite it with what was on disk before it.
    func testPreloadDoesNotDisplaceWhatMemoryAlreadyHas() async throws {
        let store = try makeStore()
        try cache(store, ["W9OTR"])
        let service = CallsignLookupService(store: store, remote: ForbiddenDirectory())

        _ = await service.resolve("W9OTR")
        let first = service.cached("W9OTR")
        service.preload(["W9OTR", "W9OTR-7"])

        XCTAssertEqual(service.cached("W9OTR")?.fetchedAt, first?.fetchedAt)
        XCTAssertEqual(service.records.count, 1, "SSIDs of one box are one record")
    }

    // MARK: - Pacing

    /// The courtesy gap is owed to the remote directory, and a cache read
    /// never reaches it. `resolving` reports which happened so a bulk
    /// caller can wait for one and not the other.
    func testACacheHitIsReportedAsCacheAndANetworkAnswerAsNetwork() async throws {
        let store = try makeStore()
        try cache(store, ["KE0NCQ"])
        let service = CallsignLookupService(
            store: store, remote: ForbiddenDirectory(), isNetworkEnabled: true)

        let cached = await service.resolving("KE0NCQ")
        XCTAssertEqual(cached.origin, .cache)
        XCTAssertNotNil(cached.record)

        // Second time it is in memory rather than on disk — still a
        // local read, still no gap owed.
        let again = await service.resolving("KE0NCQ")
        XCTAssertEqual(again.origin, .cache)

        // Nothing cached and the remote has no answer: the request went
        // out, so the gap is owed even though nothing came back.
        let missed = await service.resolving("N0BODY")
        XCTAssertEqual(missed.origin, .network)
        XCTAssertNil(missed.record)
    }

    func testNothingIsOwedWhenTheNetworkIsNotConsultedAtAll() async throws {
        let service = CallsignLookupService(
            store: try makeStore(), remote: ForbiddenDirectory(),
            isNetworkEnabled: false)

        let refused = await service.resolving("N0BODY")
        XCTAssertEqual(refused.origin, .none,
                       "lookups off: no query, no wait")
    }
}
