import XCTest
@testable import AXTerm

/// The reconnect backoff for a flapping LAN radio.
///
/// A LAN session can come up, be granted audio, and then have every CI-V poll
/// ignored — it drops within a second or two. The old code reset the backoff
/// the instant the rig came up, so a flap counted as a success: the backoff
/// never grew and the app hammered the radio every few seconds, never leaving
/// it the quiet window it needs to release a stale CI-V attachment. And after a
/// fixed number of attempts it gave up entirely, stranding a radio that would
/// have recovered on its own.
///
/// These pin the two behaviours that fix that: the delay grows and caps, and
/// the attempt counter never terminates.
final class ModemRadioLinkBackoffTests: XCTestCase {

    /// The delay doubles from the base and then holds at the ceiling.
    func testBackoffGrowsThenCaps() {
        XCTAssertEqual(ModemRadioLink.reconnectBackoff(attempt: 1), 3, accuracy: 0.001)
        XCTAssertEqual(ModemRadioLink.reconnectBackoff(attempt: 2), 6, accuracy: 0.001)
        XCTAssertEqual(ModemRadioLink.reconnectBackoff(attempt: 3), 12, accuracy: 0.001)
        XCTAssertEqual(ModemRadioLink.reconnectBackoff(attempt: 4), 24, accuracy: 0.001)
        // 48 would exceed the 30 s ceiling, so it is held there.
        XCTAssertEqual(ModemRadioLink.reconnectBackoff(attempt: 5), 30, accuracy: 0.001)
        XCTAssertEqual(ModemRadioLink.reconnectBackoff(attempt: 50), 30, accuracy: 0.001)
    }

    /// The counter advances one at a time and then clamps — it never runs away.
    func testAttemptAdvancesThenClamps() {
        XCTAssertEqual(ModemRadioLink.nextReconnectAttempt(0), 1)
        XCTAssertEqual(ModemRadioLink.nextReconnectAttempt(1), 2)
        // Once at the cap it stays there rather than climbing further.
        let capped = ModemRadioLink.nextReconnectAttempt(8)
        XCTAssertEqual(ModemRadioLink.nextReconnectAttempt(capped), capped)
    }

    /// The regression that stranded a recoverable radio: driving the counter
    /// well past the cap keeps producing a real, capped delay every time, so
    /// the link keeps retrying instead of giving up.
    func testKeepsRetryingForeverAtTheCeiling() {
        var attempt = 0
        for _ in 0..<100 {
            attempt = ModemRadioLink.nextReconnectAttempt(attempt)
            let delay = ModemRadioLink.reconnectBackoff(attempt: attempt)
            XCTAssertGreaterThan(delay, 0)
            XCTAssertLessThanOrEqual(delay, 30)
        }
        // Far past the old give-up point, the delay is pinned at the ceiling
        // and the loop above never stopped scheduling.
        XCTAssertEqual(ModemRadioLink.reconnectBackoff(attempt: attempt), 30, accuracy: 0.001)
    }
}
