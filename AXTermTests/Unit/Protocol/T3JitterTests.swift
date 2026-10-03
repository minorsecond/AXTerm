//
//  T3JitterTests.swift
//  AXTermTests
//
//  Each T3 period is drawn at random between three quarters of T3 and T3.
//
//  Smoke run 2026-10-03-1, issue 6: both stations ran T3 at exactly 30 s and
//  restarted it on the same exchange, so their idle polls went out together
//  and collided. AX.25 2.2 §6.7.1.3 leaves the period "locally defined";
//  p-persistence (§6.7.1.6) is the spec's own answer to collisions, but it
//  cannot separate two stations that key up within one slot of each other.
//  The draw stays at or under T3 because peers give up on a silent link not
//  long after it (AX25SessionTests.testT3TimeoutValueIsReasonable).
//

import XCTest
@testable import AXTerm

@MainActor
final class T3JitterTests: XCTestCase {

    private let local = AX25Address(call: "K0BBB", ssid: 2)
    private let peer = AX25Address(call: "K0AAA", ssid: 1)

    private func connected(clock: AX25VirtualClock, draw: @escaping () -> Double)
        -> (AX25SessionManager, () -> [OutboundFrame]) {
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.t3JitterDraw = draw
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        XCTAssertEqual(manager.session(for: peer, path: DigiPath(), radio: .primary).state, .connected)
        return (manager, { sent })
    }

    private func polls(_ sent: [OutboundFrame]) -> Int {
        sent.filter { $0.frameType == "s" && $0.isCommand == true && ($0.controlByte ?? 0) & 0x10 != 0 }.count
    }

    func testT3FiresAtItsDrawnPeriod() {
        let clock = AX25VirtualClock()
        let (manager, sent) = connected(clock: clock, draw: { 0.6 })  // 30 × (1 − 0.25 × 0.6) = 25.5 s
        defer { withExtendedLifetime(manager) {} }

        clock.advance(by: 25.4)
        XCTAssertEqual(polls(sent()), 0, "T3 fired before its drawn period")
        clock.advance(by: 0.2)
        XCTAssertEqual(polls(sent()), 1, "T3 did not fire at its drawn period")
    }

    func testEveryDrawLiesBetweenThreeQuartersOfT3AndT3() {
        for draw in [0.0, 0.25, 0.5, 0.999, 1.0, -1.0, 7.0] {
            let delay = AX25SessionManager.t3Delay(base: 30, draw: draw)
            XCTAssertGreaterThanOrEqual(delay, 22.5, "draw \(draw)")
            XCTAssertLessThanOrEqual(delay, 30, "draw \(draw)")
        }
    }

    /// Two stations started on the same exchange poll at different moments.
    func testTwoStationsWithDifferentDrawsPollApart() {
        let clock = AX25VirtualClock()
        let (a, sentA) = connected(clock: clock, draw: { 0.1 })   // 29.25 s
        let (b, sentB) = connected(clock: clock, draw: { 0.9 })   // 23.25 s
        defer { withExtendedLifetime((a, b)) {} }

        clock.advance(by: 24)
        XCTAssertEqual(polls(sentB()), 1)
        XCTAssertEqual(polls(sentA()), 0)
    }

    /// The app's own source of draws is not a constant: two stations running
    /// the same build must not pick the same periods.
    func testTheDefaultDrawsVary() {
        let manager = AX25SessionManager(localCallsign: local, clock: AX25VirtualClock())
        let draws = (0..<32).map { _ in manager.t3JitterDraw() }
        XCTAssertGreaterThan(Set(draws).count, 1)
        XCTAssertTrue(draws.allSatisfy { (0..<1).contains($0) })
    }
}
