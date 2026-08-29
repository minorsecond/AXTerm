import XCTest
@testable import AXTerm

/// The host is a state machine — caller modes, bridge lifecycle, line
/// assembly — and state machines get tests. Faked at both seams: the
/// circuit layer (NodeCircuitOps) and the mailbox (NodeMailboxSession).
@MainActor
final class NetRomNodeHostTests: XCTestCase {

    /// A circuit layer that records everything and connects on demand.
    final class FakeCircuits: NodeCircuitOps, @unchecked Sendable {
        var sent: [(id: NetRomCircuitID, data: Data)] = []
        var disconnected: [NetRomCircuitID] = []
        var opened: [(destination: String, id: NetRomCircuitID)] = []
        var routeExists = true
        func send(_ data: Data, on id: NetRomCircuitID) { sent.append((id, data)) }
        func disconnect(_ id: NetRomCircuitID) { disconnected.append(id) }
        func openNodeCircuit(to destination: AX25Address) -> NetRomCircuitID? {
            guard routeExists else { return nil }
            let id = NetRomCircuitID()
            opened.append((destination.display, id))
            return id
        }
        func text(on id: NetRomCircuitID) -> String {
            String(decoding: Data(sent.filter { $0.id == id }.flatMap { $0.data }),
                   as: UTF8.self)
        }
    }

    final class FakeMailbox: NodeMailboxSession {
        var handled: [String] = []
        var closeOnNext = false
        func greeting() -> (lines: [String], prompt: String?) {
            (["Mailbox open."], "BBS> ")
        }
        func handle(line: String) -> (lines: [String], prompt: String?, closed: Bool) {
            handled.append(line)
            return closeOnNext ? (["73."], nil, true) : (["ok"], "BBS> ", false)
        }
    }

    private var host: NetRomNodeHost!
    private var circuits: FakeCircuits!
    private var written: [Data] = []
    private var hangUps = 0
    private var pendingTimeouts: [() -> Void] = []

    override func setUp() async throws {
        host = NetRomNodeHost()
        circuits = FakeCircuits()
        host.useCircuitOps(circuits)
        host.isEnabled = true
        host.identityProvider = { ("EPINOD", "K0EPI-7", "AXTerm 1.0") }
        host.snapshotProvider = {
            var snapshot = NetRomNodeShell.Snapshot()
            snapshot.neighbors = [.init(callsign: "KB5YZB-7", quality: 192, count: 4)]
            snapshot.bbsAvailable = true
            return snapshot
        }
        host.scheduleTimeout = { [weak self] _, work in
            self?.pendingTimeouts.append(work)
        }
        written = []
        hangUps = 0
        pendingTimeouts = []
    }

    private func attachCaller() {
        host.attachAX25Caller(
            key: "S1", callsign: "W0ARP-1",
            send: { [weak self] data in self?.written.append(data) },
            hangUp: { [weak self] in self?.hangUps += 1 })
    }

    private var callerText: String {
        String(decoding: Data(written.flatMap { $0 }), as: UTF8.self)
    }

    private func type(_ line: String) {
        host.ax25CallerReceived(key: "S1", data: Data((line + "\r").utf8))
    }

    // MARK: - Session basics

    func testAnAX25CallerIsGreetedAndCanAskQuestions() {
        attachCaller()
        XCTAssertTrue(callerText.contains("AXTerm 1.0 Node EPINOD:K0EPI-7"))
        XCTAssertTrue(callerText.hasSuffix("EPINOD:K0EPI-7} "))

        type("ROUTES")
        XCTAssertTrue(callerText.contains("> 1 KB5YZB-7 192 4"))
    }

    func testLinesSurviveArbitraryChunking() {
        attachCaller()
        written = []
        host.ax25CallerReceived(key: "S1", data: Data("ROU".utf8))
        XCTAssertTrue(written.isEmpty, "half a line is not a command")
        host.ax25CallerReceived(key: "S1", data: Data("TES\r\nMH\r".utf8))
        XCTAssertTrue(callerText.contains("Routes"))
        XCTAssertTrue(callerText.contains("Nothing heard yet."),
                      "both lines in one chunk both get answered")
    }

    func testByeHangsUpTheCallersOwnLink() {
        attachCaller()
        type("BYE")
        XCTAssertEqual(hangUps, 1)
        XCTAssertTrue(callerText.contains("73 de EPINOD"))
    }

    // MARK: - BBS handoff

    func testBBSHandsOffAndReturnsToTheNodeOnMailboxBye() {
        let mailbox = FakeMailbox()
        host.bbsSessionFactory = { _ in mailbox }
        attachCaller()

        type("BBS")
        XCTAssertTrue(callerText.contains("Mailbox open."))

        type("L")
        XCTAssertEqual(mailbox.handled, ["L"],
                       "in BBS mode, lines go to the mailbox, not the node shell")

        mailbox.closeOnNext = true
        type("B")
        XCTAssertTrue(callerText.contains("Back at the node."))
        written = []
        type("ROUTES")
        XCTAssertTrue(callerText.contains("Routes"),
                      "after the mailbox closes, the node shell answers again")
    }

    // MARK: - C bridging

    func testCDialsBridgesAndPipesBothWays() {
        attachCaller()
        type("C COSCO")
        XCTAssertEqual(circuits.opened.count, 1)
        XCTAssertTrue(callerText.contains("Trying COSCO"))
        let outbound = circuits.opened[0].id

        // Keystrokes while dialing are swallowed, not queued.
        type("HELLO?")
        XCTAssertTrue(circuits.sent.isEmpty)

        host.circuitConnected(outbound)
        XCTAssertTrue(callerText.contains("*** Connected to COSCO"))

        // Caller → far side.
        host.ax25CallerReceived(key: "S1", data: Data("hi there\r".utf8))
        XCTAssertEqual(circuits.text(on: outbound), "hi there\r")

        // Far side → caller, byte-transparent.
        written = []
        host.consumeCircuit(id: outbound, data: Data("hello back\r".utf8))
        XCTAssertEqual(callerText, "hello back\r")
    }

    func testTheFarSideDisconnectingReturnsTheCallerToThePrompt() {
        attachCaller()
        type("C COSCO")
        let outbound = circuits.opened[0].id
        host.circuitConnected(outbound)

        host.circuitClosed(outbound)
        XCTAssertTrue(callerText.contains("*** Disconnected from COSCO"))
        XCTAssertTrue(callerText.hasSuffix("EPINOD:K0EPI-7} "))

        written = []
        type("MH")
        XCTAssertTrue(callerText.contains("Nothing heard yet."),
                      "the shell is back in charge")
    }

    func testADialThatNeverConnectsIsAbandonedAndSpoken() {
        attachCaller()
        type("C COSCO")
        let outbound = circuits.opened[0].id

        XCTAssertEqual(pendingTimeouts.count, 1)
        pendingTimeouts[0]()
        XCTAssertEqual(circuits.disconnected, [outbound],
                       "60 s of silence beats six minutes of CONREQ retries")
        host.circuitClosed(outbound)
        XCTAssertTrue(callerText.contains("*** Failure with COSCO"))
    }

    func testTheTimeoutIsHarmlessOnceBridged() {
        attachCaller()
        type("C COSCO")
        let outbound = circuits.opened[0].id
        host.circuitConnected(outbound)
        pendingTimeouts[0]()
        XCTAssertTrue(circuits.disconnected.isEmpty,
                      "a connected bridge must not be killed by its own dial timer")
    }

    func testNoRouteIsSpokenImmediately() {
        circuits.routeExists = false
        attachCaller()
        type("C NOWHERE")
        XCTAssertTrue(callerText.contains("*** No route to NOWHERE"))
        XCTAssertTrue(callerText.hasSuffix("EPINOD:K0EPI-7} "))
    }

    func testTheCallerLeavingTearsTheBridgeDown() {
        attachCaller()
        type("C COSCO")
        let outbound = circuits.opened[0].id
        host.circuitConnected(outbound)

        host.ax25CallerClosed(key: "S1")
        XCTAssertEqual(circuits.disconnected, [outbound],
                       "an orphaned outbound circuit is airtime for nobody")
    }

    // MARK: - Inbound circuit callers

    func testAnInboundCircuitCallerGetsTheSameShell() {
        let inbound = NetRomCircuitID()
        host.inboundCircuitOpened(inbound, caller: "VE3CGR-1")
        XCTAssertEqual(host.activeCallerCount, 1,
                       "pending callers count toward the capacity cap")

        host.circuitConnected(inbound)
        XCTAssertTrue(circuits.text(on: inbound)
            .contains("AXTerm 1.0 Node EPINOD:K0EPI-7"))

        host.consumeCircuit(id: inbound, data: Data("ROUTES\r".utf8))
        XCTAssertTrue(circuits.text(on: inbound).contains("> 1 KB5YZB-7 192 4"))
    }
}
