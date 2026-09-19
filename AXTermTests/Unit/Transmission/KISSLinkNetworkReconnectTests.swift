import XCTest
@testable import AXTerm

/// The TCP link coming back by itself.
///
/// For a long time this was the one transport that did not. Serial and
/// Bluetooth have had auto-reconnect since they were written; a failed TCP
/// connection sat there until somebody clicked Connect. On 2026-09-18 the
/// socket to Direwolf on a Raspberry Pi was reset at about 20:20 and the
/// station stayed off the air until the operator came back the next morning,
/// with the app running and the network up the whole time.
final class KISSLinkNetworkReconnectTests: XCTestCase {

    /// A port nothing is listening on, and loopback because an XCTest host may
    /// not reach anything else (`AppEnvironment.mayConnect`).
    private func link(autoReconnect: Bool = true) -> KISSLinkNetwork {
        KISSLinkNetwork(host: "127.0.0.1", port: 59_417,
                        autoReconnect: autoReconnect,
                        stableConnectionSeconds: 0.05)
    }

    // MARK: - The backoff

    /// Doubling from a small base and capped, which is `ModemRadioLink`'s
    /// policy rather than a second invention.
    func testTheDelayDoublesAndThenStops() {
        XCTAssertEqual(KISSLinkNetwork.reconnectBackoff(attempt: 1), 1)
        XCTAssertEqual(KISSLinkNetwork.reconnectBackoff(attempt: 2), 2)
        XCTAssertEqual(KISSLinkNetwork.reconnectBackoff(attempt: 3), 4)
        XCTAssertEqual(KISSLinkNetwork.reconnectBackoff(attempt: 4), 8)
        XCTAssertEqual(KISSLinkNetwork.reconnectBackoff(attempt: 5), 16)
        XCTAssertEqual(KISSLinkNetwork.reconnectBackoff(attempt: 6), 30)
        XCTAssertEqual(KISSLinkNetwork.reconnectBackoff(attempt: 99), 30, "capped, not unbounded")
    }

    /// Attempt zero is the first attempt, not a negative exponent.
    func testTheFirstDelayIsNotDegenerate() {
        XCTAssertEqual(KISSLinkNetwork.reconnectBackoff(attempt: 0), 1)
    }

    /// Clamped rather than terminal. The old `ModemRadioLink` gave up once the
    /// count passed its cap and left the operator with a dead radio that would
    /// have recovered on its own; this never stops trying.
    func testTheAttemptCounterClampsInsteadOfGivingUp() {
        var attempt = 0
        for _ in 0..<50 { attempt = KISSLinkNetwork.nextReconnectAttempt(attempt) }
        XCTAssertEqual(attempt, 8)
        XCTAssertEqual(KISSLinkNetwork.reconnectBackoff(attempt: attempt), 30)
    }

    /// Thirty seconds at the ceiling: a Pi that is rebooting is back inside a
    /// minute of that, and a link retried every thirty seconds forever is not
    /// a load on anything.
    func testTheCeilingIsHalfAMinute() {
        XCTAssertEqual(KISSLinkNetwork.reconnectBackoff(attempt: 8), 30)
    }

    // MARK: - What the operator asked for

    func testOpeningMarksTheLinkWanted() {
        let l = link()
        l.open()
        XCTAssertEqual(l.state, .connecting)
        l.close()
    }

    /// A deliberate close is the operator changing their mind, and must not be
    /// undone by a timer that was already in flight.
    func testClosingStopsItComingBack() {
        let l = link()
        l.open()
        l.close()
        XCTAssertEqual(l.state, .disconnected)

        let settled = expectation(description: "stays closed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(l.state, .disconnected, "a closed link does not reopen itself")
    }

    /// A close also clears the backoff, so the next open starts from the base
    /// rather than serving out a penalty from last time.
    func testClosingClearsTheBackoff() {
        let l = link()
        l.testReconnectAttempt = 6
        l.close()
        XCTAssertEqual(l.testReconnectAttempt, 0)
    }

    // MARK: - Sleep

    /// Sleep is not the operator changing their mind. The socket goes down so
    /// the far end sees a close rather than a client that stopped answering,
    /// and the link stays wanted.
    func testSuspendingPutsItDownButKeepsItWanted() {
        let l = link()
        l.open()
        l.suspend()
        XCTAssertEqual(l.state, .disconnected)

        l.resume()
        XCTAssertEqual(l.state, .connecting, "still wanted, so it comes back")
        l.close()
    }

    /// Waking clears the backoff. The drop was expected, and making the
    /// station serve a penalty for the operator's lid is how a node stays off
    /// the air long after its Mac is awake.
    func testWakingDoesNotMakeItServeABackoff() {
        let l = link()
        l.open()
        l.testReconnectAttempt = 8
        l.suspend()
        l.resume()
        XCTAssertEqual(l.testReconnectAttempt, 0)
        l.close()
    }

    /// A link the operator had already closed stays closed through a sleep.
    /// Waking is not an excuse to open radios nobody asked for.
    func testSleepDoesNotReviveAClosedLink() {
        let l = link()
        l.open()
        l.close()
        l.suspend()
        l.resume()
        XCTAssertEqual(l.state, .disconnected)
    }

    /// A link that was never opened has nothing to suspend.
    func testSuspendingAnUnopenedLinkDoesNothing() {
        let l = link()
        l.suspend()
        l.resume()
        XCTAssertEqual(l.state, .disconnected)
    }

    // MARK: - Failures not worth retrying

    /// Port zero is a settled fact, not a transient one, and retrying it would
    /// be an infinite loop with a delay in it.
    ///
    /// It has to be rejected by hand: `NWEndpoint.Port(rawValue: 0)` succeeds
    /// and means "any", which for an outbound connection is not a port.
    func testPortZeroFailsAndStaysFailed() {
        let l = KISSLinkNetwork(host: "127.0.0.1", port: 0, autoReconnect: true)
        l.open()
        XCTAssertEqual(l.state, .failed)

        let settled = expectation(description: "stays failed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(l.state, .failed, "nothing to retry against")
        l.close()
    }

    /// A host this process may not reach is settled too. Under XCTest that is
    /// anything but loopback (`AppEnvironment.mayConnect`), and a backoff
    /// against it would retry a refusal forever.
    func testAHostThisProcessMayNotReachIsNotRetried() {
        let l = KISSLinkNetwork(host: "ham-pi.invalid", port: 8001, autoReconnect: true)
        l.open()
        XCTAssertEqual(l.state, .failed)

        let settled = expectation(description: "stays failed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(l.state, .failed)
        l.close()
    }

    /// Turning it off turns it off. The switch exists because serial and
    /// Bluetooth have one, and a transport that ignored it would be a lie.
    func testAutoReconnectCanBeTurnedOff() {
        let l = link(autoReconnect: false)
        XCTAssertFalse(l.autoReconnect)
        l.open()
        l.close()
        XCTAssertEqual(l.state, .disconnected)
    }
}
