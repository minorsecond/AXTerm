import XCTest
@testable import AXTerm

/// When a sync pass runs, and what the operator is told about it.
@MainActor
final class WinlinkSyncControllerTests: XCTestCase {

    /// Counts passes without touching a network or a database.
    private final class CountingTransport: WinlinkSyncTransport, @unchecked Sendable {
        let deviceID = "counting"
        private let lock = NSLock()
        private var _passes = 0
        var available = true
        var fetchError: Error?

        var passes: Int {
            lock.lock(); defer { lock.unlock() }
            return _passes
        }

        func isAvailable() async -> Bool { available }

        func fetchChanges(since token: Data?) async throws -> WinlinkSyncChangeSet {
            if let fetchError { throw fetchError }
            lock.lock(); _passes += 1; lock.unlock()
            return WinlinkSyncChangeSet()
        }

        func push(_ records: [WinlinkSyncRecord]) async throws {}
    }

    private struct SilentSource: WinlinkSyncSource {
        let kind: WinlinkSyncPolicy.Kind = .messageState
        func localRecords() throws -> [WinlinkSyncRecord] { [] }
        func apply(_ records: [WinlinkSyncRecord]) throws -> Int { 0 }
    }

    private func makeController(transport: CountingTransport,
                                enabled: Bool = true) -> WinlinkSyncController {
        WinlinkSyncController(
            engine: WinlinkSyncEngine(transport: transport,
                                      sources: [SilentSource()],
                                      tokenStore: WinlinkMemoryTokenStore()),
            isEnabled: { enabled })
    }

    /// Waits for the controller to settle rather than sleeping a fixed
    /// interval, so the test is not a race on a slow machine.
    private func settle(_ controller: WinlinkSyncController) async {
        for _ in 0..<200 {
            if !controller.status.isBusy { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("sync never finished")
    }

    // MARK: Triggers

    func testSessionCompletionTriggersAPass() async {
        let transport = CountingTransport()
        let controller = makeController(transport: transport)

        controller.onSessionFinished()
        await settle(controller)

        XCTAssertEqual(transport.passes, 1)
    }

    /// The switch is the operator's, and an off switch must mean nothing
    /// leaves the machine — not merely that the UI hides it.
    func testNothingRunsWhileSyncIsOff() async {
        let transport = CountingTransport()
        let controller = makeController(transport: transport, enabled: false)

        controller.onForeground()
        controller.onSessionFinished()
        controller.syncNow()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transport.passes, 0)
        XCTAssertEqual(controller.status, .disabled)
    }

    /// A periodic tick landing on a session-triggered pass would waste a
    /// round trip and leave the status flickering between two truths.
    func testConcurrentTriggersCollapseToOnePass() async {
        let transport = CountingTransport()
        let controller = makeController(transport: transport)

        controller.onSessionFinished()
        controller.syncNow()
        controller.syncNow()
        await settle(controller)

        XCTAssertEqual(transport.passes, 1)
    }

    // MARK: Status

    /// A signed-out device works alone. That is a state to explain, not an
    /// error to raise at somebody standing in a field.
    func testNoAccountReadsAsUnavailableNotFailure() async {
        let transport = CountingTransport()
        transport.available = false
        let controller = makeController(transport: transport)

        controller.syncNow()
        await settle(controller)

        guard case .unavailable = controller.status else {
            return XCTFail("expected unavailable, got \(controller.status)")
        }
        XCTAssertTrue(controller.status.detail.contains("works alone"))
    }

    func testTransportFailureIsReportedWithItsReason() async {
        let transport = CountingTransport()
        transport.fetchError = WinlinkSyncError.accountUnavailable("quota")
        let controller = makeController(transport: transport)

        controller.syncNow()
        await settle(controller)

        guard case .failed = controller.status else {
            return XCTFail("expected failure, got \(controller.status)")
        }
        XCTAssertTrue(controller.status.detail.contains("Nothing was lost"))
    }

    /// Every status must say something specific. "Syncing…" with no account
    /// of what moved is what makes people distrust sync.
    func testEveryStatusExplainsItself() {
        let statuses: [WinlinkSyncController.Status] = [
            .disabled,
            .syncing,
            .idle(lastPass: nil, at: nil),
            .idle(lastPass: WinlinkSyncEngine.Report(pulled: 3, applied: 2, pushed: 1), at: Date()),
            .unavailable("no account"),
            .failed("timeout", at: Date()),
        ]
        for status in statuses {
            XCTAssertFalse(status.summary.isEmpty, "\(status)")
            XCTAssertGreaterThan(status.detail.count, 20, "\(status)")
        }
    }

    /// The detail must name what does *not* travel. An operator who assumes
    /// their digipeater path followed them to a handheld would key up on a
    /// route that cannot work.
    func testDetailNamesWhatStaysOnTheDevice() {
        let status = WinlinkSyncController.Status.idle(
            lastPass: WinlinkSyncEngine.Report(pulled: 1, applied: 1, pushed: 0), at: Date())
        let detail = status.detail
        XCTAssertTrue(detail.contains("Digipeater paths"))
        XCTAssertTrue(detail.contains("session logs"))
    }

    func testRefusalsAndUnreadableRecordsAreSurfaced() {
        let status = WinlinkSyncController.Status.idle(
            lastPass: WinlinkSyncEngine.Report(pulled: 5, applied: 1, pushed: 0,
                                               refused: 2, unreadable: 1, wasReset: true),
            at: Date())
        XCTAssertTrue(status.detail.contains("could not be read"))
        XCTAssertTrue(status.detail.contains("refused by policy"))
        XCTAssertTrue(status.detail.contains("re-read everything"))
    }

    // MARK: Device identity

    /// The identifier must survive relaunches, or every restart would look
    /// like a new device and orphan the claims held by the old one.
    func testDeviceIdentifierIsStable() {
        let defaults = UserDefaults(suiteName: "sync-device-test")!
        defaults.removePersistentDomain(forName: "sync-device-test")

        let first = WinlinkSyncDevice.identifier(defaults: defaults)
        let second = WinlinkSyncDevice.identifier(defaults: defaults)

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }
}
