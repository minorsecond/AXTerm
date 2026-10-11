import XCTest
@testable import AXTerm

/// The caller's side of asking a mailbox which areas take its uploads
/// (retest 2026-10-10, finding 5).
@MainActor
final class UploadAreasQueryTests: XCTestCase {

    private let mailbox = AX25Address(call: "K0EPI", ssid: 4)

    private func connected(_ coordinator: SessionCoordinator) -> AX25Session {
        coordinator.sessionManager.localCallsign = AX25Address(call: "K0EPI", ssid: 3)
        let session = coordinator.sessionManager.session(for: mailbox)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)
        return session
    }

    func testTheNamesTravelInTheReply() {
        let reply = AXDPUploadAreas.reply(to: 9, names: ["PARK", "OPS"])
        XCTAssertEqual(reply.type, .uploadAreasReply)
        guard case .message(let decoded, _) = AXDP.Message.frame(reply.encode()) else { return XCTFail() }
        XCTAssertEqual(AXDPUploadAreas.names(in: decoded), ["PARK", "OPS"])
        XCTAssertEqual(AXDPUploadAreas.names(in: AXDPUploadAreas.reply(to: 9, names: [])), [])
    }

    func testTheAnswerComesBackToTheAsker() async {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        _ = connected(coordinator)
        var sent: [OutboundFrame] = []
        coordinator.onFrameHandedToRadio = { sent.append($0) }

        async let areas = coordinator.requestUploadAreas(from: mailbox.display, timeout: 5)
        // Let the request go out, then answer it as the mailbox would.
        for _ in 0..<20 { await Task.yield() }
        let request = sent.compactMap { frame -> AXDP.Message? in
            guard case .message(let m, _) = AXDP.Message.frame(frame.payload) else { return nil }
            return m
        }.first { $0.type == .uploadAreasRequest }
        XCTAssertNotNil(request, "the request went to the mailbox")
        coordinator.testHandleAXDPMessage(AXDPUploadAreas.reply(to: request?.messageId ?? 0, names: ["PARK"]),
                                          from: mailbox)
        let result = await areas
        XCTAssertEqual(result, ["PARK"])
    }

    func testNoAnswerMeansNoPicker() async {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        _ = connected(coordinator)
        let result = await coordinator.requestUploadAreas(from: mailbox.display, timeout: 0.2)
        XCTAssertNil(result)
    }

    /// Asked of a station that is not a mailbox (a terminal), AXTerm says
    /// there are no areas at once, rather than leave the asker waiting.
    func testATerminalAnswersWithNoAreas() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        _ = connected(coordinator)
        var sent: [OutboundFrame] = []
        coordinator.onFrameHandedToRadio = { sent.append($0) }
        coordinator.testHandleAXDPMessage(AXDP.Message(type: .uploadAreasRequest, sessionId: 0, messageId: 5),
                                          from: mailbox)
        let reply = sent.compactMap { frame -> AXDP.Message? in
            guard case .message(let m, _) = AXDP.Message.frame(frame.payload) else { return nil }
            return m
        }.first
        XCTAssertEqual(reply?.type, .uploadAreasReply)
        XCTAssertEqual(reply?.messageId, 5)
        XCTAssertEqual(reply.map(AXDPUploadAreas.names(in:)), [])
    }
}
