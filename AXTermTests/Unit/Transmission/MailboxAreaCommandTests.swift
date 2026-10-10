import XCTest
@testable import AXTerm

/// The Send File sheet's mailbox area (home retest 2026-10-10, finding 11).
/// Filled in, it types `U <AREA>` into the session before the file goes, so
/// an AXTerm mailbox that trusts the caller puts the upload in that area.
@MainActor
final class MailboxAreaCommandTests: XCTestCase {

    func testTheCommandIsUWithTheAreaAsCallersTypeIt() {
        XCTAssertEqual(MailboxAreaCommand.line(for: " park "), "U PARK\r")
        XCTAssertEqual(MailboxAreaCommand.line(for: "Field Day"), "U FIELDDAY\r")
        XCTAssertNil(MailboxAreaCommand.line(for: "  "))
    }

    /// It goes down the session with the station, as a typed line would.
    func testItIsSentOnTheSessionBeforeTheFile() throws {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.sessionManager.localCallsign = AX25Address(call: "K0EPI", ssid: 3)
        let mailbox = AX25Address(call: "K0EPI", ssid: 4)
        let session = coordinator.sessionManager.session(for: mailbox)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)
        var sent: [OutboundFrame] = []
        coordinator.onFrameHandedToRadio = { sent.append($0) }

        XCTAssertTrue(coordinator.sendMailboxAreaCommand("park", to: "K0EPI-4"))
        XCTAssertEqual(sent.last.map { String(decoding: $0.payload, as: UTF8.self) }, "U PARK\r")
        XCTAssertEqual(sent.last?.destination.display, "K0EPI-4")
        XCTAssertFalse(coordinator.sendMailboxAreaCommand("park", to: "W0ARP-1"), "no session with that station")
    }
}
