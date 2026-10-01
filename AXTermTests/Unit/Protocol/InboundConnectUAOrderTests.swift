//
//  InboundConnectUAOrderTests.swift
//  AXTermTests
//
//  The UA that accepts an inbound connect goes on the air before anything
//  the layer above sends on the new link.
//
//  Found on the air 2026-10-01 17:08 UTC: K0EPI-2 called the mailbox on
//  K0EPI-3, and B handed the TNC the greeting's I(0) and I(1) and only then
//  the UA, all in the same millisecond. A received them in that order,
//  discarded the two I-frames as a station still waiting for UA must, and B
//  resent both after T1. The session manager told the layer above the link
//  was up before it built the UA, and the mailbox sends its greeting from
//  inside that notification.
//

import XCTest
@testable import AXTerm

@MainActor
final class InboundConnectUAOrderTests: XCTestCase {

    private let local = AX25Address(call: "K0EPI", ssid: 3)
    private let peer = AX25Address(call: "K0EPI", ssid: 2)

    private func manager() -> AX25SessionManager {
        let manager = AX25SessionManager(localCallsign: local, clock: AX25VirtualClock())
        manager.defaultConfig = AX25SessionConfig(windowSize: 2, paclen: 128)
        return manager
    }

    /// A service that greets every caller the moment the link comes up, the
    /// way the mailbox does, putting its frames on `wire`.
    private func greetOnConnect(_ manager: AX25SessionManager, onto wire: @escaping (OutboundFrame) -> Void) {
        manager.onSessionStateChanged = { session, _, new in
            guard new == .connected else { return }
            let frames = manager.sendData(Data("AXTerm personal mailbox\r".utf8),
                                          to: session.remoteAddress, path: session.path,
                                          radio: session.radio)
            frames.forEach(wire)
        }
    }

    func testTheUAGoesOutBeforeTheGreeting() {
        let manager = manager()
        var wire: [OutboundFrame] = []
        greetOnConnect(manager) { wire.append($0) }

        manager.answerInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary) {
            wire.append($0)
        }

        XCTAssertEqual(wire.first?.displayInfo, "UA", "nothing may precede the UA")
        XCTAssertGreaterThan(wire.count, 1, "the greeting was sent")
        XCTAssertTrue(wire.dropFirst().allSatisfy { $0.frameType == "i" })
    }

    /// A SABM on a connected link with frames in flight is a reset: the layer
    /// above is told the old link ended and a new one began. Whatever it
    /// sends in answer belongs after the UA too.
    func testAfterALinkResetTheUAStillGoesFirst() {
        let manager = manager()
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        _ = manager.sendData(Data(repeating: 0x41, count: 300), to: peer, path: DigiPath(), radio: .primary)

        var wire: [OutboundFrame] = []
        greetOnConnect(manager) { wire.append($0) }
        manager.answerInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary) {
            wire.append($0)
        }

        XCTAssertEqual(wire.first?.displayInfo, "UA")
        XCTAssertGreaterThan(wire.count, 1, "the layer above answered the new link")
    }

    /// The answer-only form still hands back the UA for callers that send
    /// it themselves.
    func testHandleInboundSABMStillReturnsTheUA() {
        let ua = manager().handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        XCTAssertEqual(ua?.displayInfo, "UA")
    }

    /// Through the coordinator, as the app receives a call: by the time any
    /// inbound-call subscriber runs, the UA has already gone to the radio.
    func testTheCoordinatorSendsTheUABeforeSubscribersHearOfTheCall() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.localCallsign = "K0EPI-3"
        var handed: [OutboundFrame] = []
        coordinator.onFrameHandedToRadio = { handed.append($0) }
        var uaAlreadySent: Bool?
        coordinator.addInboundSessionSubscriber { _ in
            uaAlreadySent = handed.contains { $0.displayInfo == "UA" }
        }

        let sabm = Packet(from: peer, to: local, via: [], frameType: .u, control: 0x3F)
        coordinator.handleIncomingPacket(sabm)

        XCTAssertEqual(uaAlreadySent, true, "a subscriber ran before the UA was sent")
        XCTAssertEqual(handed.filter { $0.displayInfo == "UA" }.count, 1, "one UA, not two")
    }
}
