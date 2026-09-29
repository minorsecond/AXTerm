import XCTest
@testable import AXTerm

/// What a pass actually sends.
///
/// Written after a live Mac reported `pulled=26 pushed=26` on every pass,
/// eight seconds apart: it re-uploaded the whole mailbox each time, which
/// made CloudKit report all of it as changed, which made the next pass pull
/// it all back and push it all again. The cost scaled with mailbox size
/// rather than with activity, and it never settled.
final class WinlinkSyncPushLedgerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// A source with records the test controls directly.
    private final class StubSource: WinlinkSyncSource, @unchecked Sendable {
        let kind: WinlinkSyncPolicy.Kind = .message
        private let lock = NSLock()
        private var records: [WinlinkSyncRecord]

        init(_ records: [WinlinkSyncRecord]) { self.records = records }

        func set(_ records: [WinlinkSyncRecord]) {
            lock.lock(); defer { lock.unlock() }
            self.records = records
        }

        func localRecords() throws -> [WinlinkSyncRecord] {
            lock.lock(); defer { lock.unlock() }
            return records
        }

        func apply(_ records: [WinlinkSyncRecord]) throws -> Int { 0 }
    }

    private func record(_ id: String, at date: Date) -> WinlinkSyncRecord {
        WinlinkSyncRecord(kind: .message, id: id, modifiedAt: date,
                          payload: Data("\(id)@\(date.timeIntervalSince1970)".utf8))
    }

    private func engine(_ source: StubSource,
                        _ transport: WinlinkInMemorySyncTransport,
                        _ tokens: WinlinkMemoryTokenStore) -> WinlinkSyncEngine {
        WinlinkSyncEngine(transport: transport, sources: [source], tokenStore: tokens)
    }

    // MARK: - The loop

    /// The second pass over an unchanged mailbox sends nothing.
    func testAnUnchangedMailboxIsNotPushedTwice() async throws {
        let transport = WinlinkInMemorySyncTransport()
        let tokens = WinlinkMemoryTokenStore()
        let source = StubSource([record("A", at: t(0)), record("B", at: t(0))])

        let first = try await engine(source, transport, tokens).sync()
        let second = try await engine(source, transport, tokens).sync()

        XCTAssertEqual(first.pushed, 2)
        XCTAssertEqual(second.pushed, 0, "an idle mailbox must not be re-uploaded")
        XCTAssertEqual(second.unchanged, 2)
    }

    /// And it keeps not sending, however many times it runs. This is the
    /// property that actually stops the loop.
    func testRepeatedIdlePassesStaySilent() async throws {
        let transport = WinlinkInMemorySyncTransport()
        let tokens = WinlinkMemoryTokenStore()
        let source = StubSource([record("A", at: t(0))])
        let engine = engine(source, transport, tokens)

        try await engine.sync()
        for _ in 0..<5 {
            let report = try await engine.sync()
            XCTAssertEqual(report.pushed, 0)
        }
    }

    // MARK: - Still sending what matters

    /// A new message goes up, and only that one.
    func testOnlyTheNewRecordIsPushed() async throws {
        let transport = WinlinkInMemorySyncTransport()
        let tokens = WinlinkMemoryTokenStore()
        let source = StubSource([record("A", at: t(0))])
        let engine = engine(source, transport, tokens)

        try await engine.sync()
        source.set([record("A", at: t(0)), record("B", at: t(10))])

        let report = try await engine.sync()
        XCTAssertEqual(report.pushed, 1)
    }

    /// An edited record — a read flag, a delivery state — goes up again,
    /// because its `modifiedAt` moved. Suppressing this would be worse than
    /// the loop: the other device would never learn.
    func testAChangedRecordIsPushedAgain() async throws {
        let transport = WinlinkInMemorySyncTransport()
        let tokens = WinlinkMemoryTokenStore()
        let source = StubSource([record("A", at: t(0))])
        let engine = engine(source, transport, tokens)

        try await engine.sync()
        source.set([record("A", at: t(100))])

        let report = try await engine.sync()
        XCTAssertEqual(report.pushed, 1)
    }

    /// The ledger does not grow without bound: a record this device no longer
    /// holds stops being remembered.
    func testDroppedRecordsLeaveTheLedger() async throws {
        let transport = WinlinkInMemorySyncTransport()
        let tokens = WinlinkMemoryTokenStore()
        let source = StubSource([record("A", at: t(0)), record("B", at: t(0))])
        let engine = engine(source, transport, tokens)

        try await engine.sync()
        source.set([record("C", at: t(10))])
        try await engine.sync()

        XCTAssertNil(tokens.loadPushLedger()["message|A"])
        XCTAssertNotNil(tokens.loadPushLedger()["message|C"])
    }

    /// A fresh device with no ledger pushes everything — the first pass has
    /// to seed the account.
    func testAFirstPassPushesEverything() async throws {
        let transport = WinlinkInMemorySyncTransport()
        let source = StubSource([record("A", at: t(0)), record("B", at: t(0))])
        let report = try await engine(source, transport, WinlinkMemoryTokenStore()).sync()
        XCTAssertEqual(report.pushed, 2)
    }

    /// The ledger survives a relaunch, so restarting the app does not
    /// re-upload the mailbox.
    func testTheLedgerPersistsAcrossDeviceRestarts() throws {
        let defaults = UserDefaults(suiteName: "ledger-\(UUID().uuidString)")!
        let store = WinlinkDefaultsTokenStore(defaults: defaults, key: "test.token")

        store.savePushLedger(["message|A": t(0)])
        let reloaded = WinlinkDefaultsTokenStore(defaults: defaults, key: "test.token")

        let stamp = try XCTUnwrap(reloaded.loadPushLedger()["message|A"])
        XCTAssertEqual(stamp.timeIntervalSince1970,
                       t(0).timeIntervalSince1970, accuracy: 0.001)
    }
}
