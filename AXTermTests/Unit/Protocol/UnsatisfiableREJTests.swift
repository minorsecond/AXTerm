import XCTest
@testable import AXTerm

/// A peer stuck in reject condition, asking for a frame we have never sent.
///
/// Field capture 2026-08-26, KB5YZB-7: everything we sent was acknowledged, the
/// peer kept answering `REJ(1)`, and the link traded supervisory frames every
/// T3 for minutes without carrying a byte. Nothing could satisfy it — the
/// peer's reject clears only on the I-frame it is asking for, and we had none.
///
/// §6.7.1.1: a link that cannot make progress climbs the N2 ladder and fails.
@MainActor
final class UnsatisfiableREJTests: XCTestCase {

    private let peer = AX25Address(call: "KB5YZB", ssid: 7)

    private func connected(maxRetries: Int) -> (AX25SessionManager, AX25Session) {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        manager.defaultConfig = AX25SessionConfig(maxRetries: maxRetries)
        _ = manager.connect(to: peer)
        let session = manager.session(for: peer)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)
        XCTAssertEqual(session.state, .connected)
        return (manager, session)
    }

    /// One frame out, acknowledged by the REJ itself, then the same REJ forever.
    func testRepeatedUnsatisfiableREJFailsTheLink() {
        let (manager, session) = connected(maxRetries: 3)
        _ = manager.sendData(Data("n".utf8), to: peer)
        XCTAssertEqual(session.outstandingCount, 1)

        // The first REJ acknowledges the frame — real progress, no escalation.
        _ = manager.handleInboundREJ(from: peer, path: DigiPath(), channel: 0,
                                     nr: 1, pf: true, isCommand: false)
        XCTAssertEqual(session.outstandingCount, 0)
        XCTAssertEqual(session.state, .connected)

        // Every one after that acknowledges nothing and asks for a frame that
        // does not exist. The ladder has to climb.
        for _ in 0...3 {
            _ = manager.handleInboundREJ(from: peer, path: DigiPath(), channel: 0,
                                         nr: 1, pf: true, isCommand: false)
        }
        XCTAssertEqual(session.state, .error,
                       "an unsatisfiable REJ must not repeat indefinitely")
    }

    /// §6.7.1.1 still holds: an F=1 answer clears the retry count. The escape
    /// is counted separately so fixing this livelock does not break that rule.
    func testTheSpecRetryRuleIsUntouched() {
        let (manager, session) = connected(maxRetries: 3)
        _ = manager.sendData(Data("n".utf8), to: peer)
        _ = manager.handleInboundREJ(from: peer, path: DigiPath(), channel: 0,
                                     nr: 1, pf: true, isCommand: false)
        XCTAssertEqual(session.stateMachine.retryCount, 0)
        XCTAssertEqual(session.stateMachine.unsatisfiableREJCount, 0,
                       "the acking REJ made progress")
    }

    func testUnsatisfiableREJsAreCountedSeparately() {
        let (manager, session) = connected(maxRetries: 3)
        _ = manager.sendData(Data("n".utf8), to: peer)
        _ = manager.handleInboundREJ(from: peer, path: DigiPath(), channel: 0,
                                     nr: 1, pf: true, isCommand: false)

        for _ in 0..<3 {
            _ = manager.handleInboundREJ(from: peer, path: DigiPath(), channel: 0,
                                         nr: 1, pf: true, isCommand: false)
            XCTAssertNotEqual(session.state, .error, "should not fail before N2")
        }
        _ = manager.handleInboundREJ(from: peer, path: DigiPath(), channel: 0,
                                     nr: 1, pf: true, isCommand: false)
        XCTAssertEqual(session.state, .error)
    }

    /// A REJ that acknowledges something is the link working, however oddly.
    func testAckProgressKeepsTheLinkAlive() {
        let (manager, session) = connected(maxRetries: 3)
        for index in 0..<6 {
            _ = manager.sendData(Data("frame\(index)".utf8), to: peer)
            _ = manager.handleInboundREJ(from: peer, path: DigiPath(), channel: 0,
                                         nr: (index + 1) % 8, pf: true, isCommand: false)
            XCTAssertEqual(session.state, .connected, "progress must reset the ladder")
        }
    }

    /// And a REJ we can actually act on still behaves as it did: retransmit,
    /// protected by T1, with the F=1 answer clearing timer recovery.
    func testREJWithOutstandingFramesStillRetransmits() {
        let (manager, session) = connected(maxRetries: 3)
        _ = manager.sendData(Data("one".utf8), to: peer)
        _ = manager.sendData(Data("two".utf8), to: peer)
        XCTAssertEqual(session.outstandingCount, 2)

        let frames = manager.handleInboundREJ(from: peer, path: DigiPath(), channel: 0,
                                              nr: 1, pf: true, isCommand: false)
        XCTAssertFalse(frames.isEmpty, "a satisfiable REJ must put something on the air")
        XCTAssertEqual(session.state, .connected)
    }
}
