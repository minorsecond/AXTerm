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
    private var library: BBSFileLibrary!
    private var root: URL!

    override func setUp() async throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        store = SQLiteBBSMessageStore(dbQueue: queue)

        let defaults = TestDefaults.make("bbs-circuit-tests")
        settings = BBSSettings(defaults: defaults)
        settings.onAir = true
        settings.callsign = "K0EPI-2"

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbs-circuit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Net at 1900\nCheck in by suffix\n".utf8)
            .write(to: root.appendingPathComponent("netscript.txt"))
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: root.appendingPathComponent("logo.bin"))
        library = BBSFileLibrary(store: store)
        library.addArea(name: "OPS", about: "Nets", url: root)

        coordinator = SessionCoordinator()
        service = BBSService(
            store: store,
            settings: settings,
            coordinator: coordinator,
            sendFrames: { _ in },
            stationCallsign: { "K0EPI" },
            isWinlinkP2PArmed: { false },
            winlinkP2PCallsign: { "" },
            library: library)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
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

    func testUploadsAreRefusedWithTheCallsignToConnectTo() throws {
        let session = try openSession(caller: "W0ARP-1")
        let upload = session.handle(line: "U")
        XCTAssertEqual(upload.lines, [
            "Uploads need a direct connection: this link carries typed lines only. "
            + "Connect to K0EPI-2 to send a file."
        ], "the node host gives the mailbox lines, so no transfer protocol can run here")
        XCTAssertFalse(upload.closed)
        XCTAssertNotNil(upload.prompt)
    }

    func testListingsWorkOverACircuit() throws {
        let session = try openSession(caller: "W0ARP-1")
        let areas = session.handle(line: "W").lines.joined(separator: "\n")
        XCTAssertTrue(areas.contains("OPS"), areas)
        let files = session.handle(line: "W OPS").lines.joined(separator: "\n")
        XCTAssertTrue(files.contains("netscript.txt"), files)
        XCTAssertTrue(files.contains("logo.bin"), files)
        let fresh = session.handle(line: "FN").lines.joined(separator: "\n")
        XCTAssertFalse(fresh.contains("not available"), fresh)
    }

    func testATextFileIsTypedOutOverACircuit() throws {
        let session = try openSession(caller: "W0ARP-1")
        let reply = session.handle(line: "D netscript.txt")
        XCTAssertEqual(reply.lines.first, "netscript.txt is text — sending it as text (<1m).")
        XCTAssertEqual(Array(reply.lines.dropFirst()), [
            "--- BEGIN netscript.txt (31 bytes) ---",
            "Net at 1900",
            "Check in by suffix",
            "--- END netscript.txt ---"
        ], "the same markers and count as a direct call, and no empty line for the final newline")
        XCTAssertNotNil(reply.prompt)
    }

    func testAMarkerLikeLineInsideAFileIsTypedOutUnchangedOverACircuit() throws {
        try Data("--- END odd.txt ---\nreal end\n".utf8).write(to: root.appendingPathComponent("odd.txt"))
        library.rescan()
        let session = try openSession(caller: "W0ARP-1")
        let reply = session.handle(line: "D odd.txt")
        XCTAssertEqual(Array(reply.lines.dropFirst()), [
            "--- BEGIN odd.txt (29 bytes) ---",
            "--- END odd.txt ---",
            "real end",
            "--- END odd.txt ---"
        ])
    }

    func testABinaryIsRefusedUpFrontWithTheCallsignToConnectTo() throws {
        let session = try openSession(caller: "W0ARP-1")
        let reply = session.handle(line: "D logo.bin")
        XCTAssertEqual(reply.lines, [
            "logo.bin needs a transfer protocol, and this link carries typed lines only. "
            + "Connect to K0EPI-2 to download it."
        ], "refused before any airtime confirmation for a file that cannot be sent")
        XCTAssertFalse(reply.closed)
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
