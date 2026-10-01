//
//  AX25FailedLinkPollTests.swift
//  AXTermTests
//
//  A link that gave up after N2 retries is a disconnected link. AX.25 2.2's
//  SDL ends the timer-recovery state, when the retry count reaches N2, in
//  state 0 (disconnected), and in state 0 any command frame with P=1 other
//  than SABM or UI draws a DM with F=1 ("all other commands"). That DM is how
//  a peer still holding the link learns at once that it is gone.
//
//  AXTerm's session sits in `.error` after N2 instead of `.disconnected`,
//  and `.error` ignored everything. A peer whose own retries had not run out
//  polled into silence until they did.
//

import XCTest
@testable import AXTerm

@MainActor
final class AX25FailedLinkPollTests: XCTestCase {

    private let local = AX25Address(call: "K0AAA", ssid: 1)
    private let peer = AX25Address(call: "K0BBB", ssid: 2)

    private func failedSession() -> (AX25SessionManager, AX25Session) {
        let manager = AX25SessionManager(localCallsign: local, clock: AX25VirtualClock())
        manager.defaultConfig = AX25SessionConfig(windowSize: 2, paclen: 64, maxRetries: 2)
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        _ = manager.sendData(Data("lost".utf8), to: peer, path: DigiPath(), radio: .primary)
        for _ in 0..<3 { _ = manager.handleT1Timeout(session: session) }
        XCTAssertEqual(session.state, .error, "precondition: N2 ran out")
        return (manager, session)
    }

    func testAFailedLinkAnswersAnRRPollWithDM() {
        let (manager, _) = failedSession()
        let replies = manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                                    nr: 0, pf: true, isCommand: true)
        XCTAssertEqual(replies.map(\.displayInfo), ["DM"])
        XCTAssertEqual(replies.first.map { ($0.controlByte ?? 0) & 0x10 }, 0x10, "F=1")
    }

    func testAFailedLinkAnswersAnIFramePollWithDM() {
        let (manager, _) = failedSession()
        let reply = manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                                ns: 0, nr: 0, pf: true, payload: Data("hi".utf8))
        XCTAssertEqual(reply?.displayInfo, "DM")
    }

    func testAFailedLinkStaysQuietWithoutAPoll() {
        let (manager, _) = failedSession()
        XCTAssertTrue(manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                                    nr: 0, pf: false, isCommand: false).isEmpty)
        XCTAssertNil(manager.handleInboundIFrame(from: peer, path: DigiPath(), radio: .primary,
                                                 ns: 0, nr: 0, pf: false, payload: Data("hi".utf8)))
    }
}
