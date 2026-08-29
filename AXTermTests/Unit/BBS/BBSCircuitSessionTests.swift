import XCTest
import GRDB
@testable import AXTerm

/// The mailbox over a NET/ROM circuit: same shell, same store, its own
/// state per caller — pinned against a real BBSService with a real
/// in-memory store, so the effect plumbing is exercised, not assumed.
@MainActor
final class BBSCircuitSessionTests: XCTestCase {

    private var service: BBSService!
    private var settings: BBSSettings!
    private var store: SQLiteBBSMessageStore!
    private var coordinator: SessionCoordinator!

    override func setUp() async throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        store = SQLiteBBSMessageStore(dbQueue: queue)

        let defaults = UserDefaults(suiteName: "bbs-circuit-tests")!
        defaults.removePersistentDomain(forName: "bbs-circuit-tests")
        settings = BBSSettings(defaults: defaults)
        settings.onAir = true
        settings.callsign = "K0EPI-2"

        coordinator = SessionCoordinator()
        service = BBSService(
            store: store,
            settings: settings,
            coordinator: coordinator,
            sendFrames: { _ in },
            stationCallsign: { "K0EPI" },
            isWinlinkP2PArmed: { false },
            winlinkP2PCallsign: { "" })
    }

    /// Greets, and skips the first-caller registration interview the
    /// way an uninterested caller would — with `A`.
    private func openSession(caller: String) throws -> BBSService.CircuitSession {
        let session = try XCTUnwrap(service.beginCircuitSession(caller: caller))
        let greeting = session.greeting()
        if greeting.prompt == nil {
            _ = session.handle(line: "A")
        }
        return session
    }

    func testANewCallerIsInterviewedOverACircuitToo() throws {
        let session = try XCTUnwrap(service.beginCircuitSession(caller: "W0ARP-1"))
        let greeting = session.greeting()
        XCTAssertNil(greeting.prompt,
                     "an unknown caller is asked to register before the prompt")
        XCTAssertTrue(greeting.lines.joined().contains("not met you before"))
        let skipped = session.handle(line: "A")
        XCTAssertNotNil(skipped.prompt, "A escapes the interview")
    }

    func testTheMailboxOffTheAirRefusesASession() {
        settings.onAir = false
        XCTAssertNil(service.beginCircuitSession(caller: "W0ARP-1"),
                     "no session for a mailbox that is not answering")
    }

    func testAGreetingAndAQuestionWork() throws {
        let session = try openSession(caller: "W0ARP-1")
        let listing = session.handle(line: "L")
        XCTAssertFalse(listing.closed)
        XCTAssertNotNil(listing.prompt, "the mailbox keeps prompting")
    }

    func testAMessageComposedOverACircuitLandsInTheRealStore() throws {
        let session = try openSession(caller: "W0ARP-1")
        _ = session.handle(line: "S K0EPI")
        _ = session.handle(line: "Test subject")
        _ = session.handle(line: "A line of body.")
        let done = session.handle(line: "/EX")
        XCTAssertFalse(done.closed)

        let stored = try store.allMessages()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.subject, "Test subject")
        XCTAssertEqual(stored.first?.from, "W0ARP-1")
    }

    func testFileTransfersAreDeclinedHonestly() throws {
        let session = try openSession(caller: "W0ARP-1")
        let upload = session.handle(line: "U")
        XCTAssertTrue(upload.lines.joined().contains("not available over a NET/ROM circuit"),
                      "a transfer protocol owns a byte stream the node host owns here")
        XCTAssertFalse(upload.closed)
    }

    func testByeClosesWithoutKillingTheService() throws {
        let session = try openSession(caller: "W0ARP-1")
        let bye = session.handle(line: "B")
        XCTAssertTrue(bye.closed)
        XCTAssertNotNil(service.beginCircuitSession(caller: "KD0SSP-1"),
                        "one caller leaving must not take the mailbox down")
    }

    func testTwoCallersKeepSeparateShellState() throws {
        let first = try openSession(caller: "W0ARP-1")
        let second = try openSession(caller: "KD0SSP-1")

        // First caller is mid-compose; the second's commands must not
        // land in that message.
        _ = first.handle(line: "S K0EPI")
        _ = first.handle(line: "From the first caller")
        let listing = second.handle(line: "L")
        XCTAssertFalse(listing.closed)

        _ = first.handle(line: "body")
        _ = first.handle(line: "/EX")
        let stored = try store.allMessages()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.from, "W0ARP-1",
                       "circuits multiplex; shell state must not")
    }
}
