import XCTest
import Network
@testable import AXTerm

/// Leaving the radio alone between sessions.
///
/// The IC-705 keeps one session. `close()` sends the token release and drops
/// the sockets in the same breath, so nothing confirms the radio ever saw it,
/// and a login arriving straight afterwards can land while the old session is
/// still held. What comes back looks connected — the login is answered and
/// audio flows — but CI-V never attaches, so receive works and transmit
/// cannot key, and the radio's own screen says disconnected (2026-09-17).
final class IcomLANSettleTests: XCTestCase {

    private let settle: TimeInterval = 5

    /// A first connect has no previous session to wait on, and must not be
    /// delayed for one.
    func testAFirstConnectNeverWaits() {
        XCTAssertEqual(IcomLANSession.settleRemaining(now: 1_000, lastCloseAt: 0, settle: settle), 0)
    }

    /// The case the operator hit: let go and reach straight back.
    func testReconnectingImmediatelyWaitsTheWholePeriod() {
        XCTAssertEqual(
            IcomLANSession.settleRemaining(now: 1_000, lastCloseAt: 1_000, settle: settle),
            settle, accuracy: 0.001)
    }

    /// Part-way through, only the remainder is owed — a reconnect two seconds
    /// later waits three, not five.
    func testOnlyTheRemainderIsOwed() {
        XCTAssertEqual(
            IcomLANSession.settleRemaining(now: 1_002, lastCloseAt: 1_000, settle: settle),
            3, accuracy: 0.001)
    }

    /// A radio left alone long enough is reconnected at once. The delay is
    /// for storms, not for ordinary use.
    func testAnIdleRadioIsReconnectedAtOnce() {
        XCTAssertEqual(
            IcomLANSession.settleRemaining(now: 1_060, lastCloseAt: 1_000, settle: settle), 0)
    }

    /// Never negative: a clock that goes backwards must not turn into a wait
    /// measured in hours.
    func testTheWaitIsNeverNegativeOrUnbounded() {
        let backwards = IcomLANSession.settleRemaining(
            now: 900, lastCloseAt: 1_000, settle: settle)
        XCTAssertGreaterThanOrEqual(backwards, 0)
        XCTAssertLessThanOrEqual(backwards, settle)
    }

    /// A connect timeout names the held session before the radio's settings.
    ///
    /// Relaunching never sends a clean release, so the first attempt after a
    /// rebuild routinely lands while the radio still holds the last session
    /// and the retry then succeeds. Leading with "is its WLAN on" sent the
    /// operator to check things that were already fine (2026-09-17).
    func testAConnectTimeoutBlamesTheHeldSessionFirst() {
        let message = IcomLANError.timeout("control socket").message
        XCTAssertTrue(message.contains("one session at a time"), message)
        XCTAssertTrue(message.contains("next attempt"), message)

        let wlan = message.range(of: "WLAN")
        let session = message.range(of: "one session at a time")
        XCTAssertNotNil(wlan)
        if let wlan, let session {
            XCTAssertTrue(session.lowerBound < wlan.lowerBound,
                          "the likely cause has to come before the unlikely one")
        }
    }

    /// The shipped value has to outlast the radio's release without making a
    /// deliberate reconnect feel broken.
    ///
    /// A reconnect 15s after a close answered CI-V at once; reconnects about
    /// 5s after a close did not, and one of them lost the radio's whole
    /// network session (2026-09-17). Anything under about ten seconds is
    /// back in the range that was measured to fail.
    func testTheShippedSettleOutlastsTheRadiosRelease() {
        XCTAssertGreaterThanOrEqual(IcomLANSession.settleAfterClose, 10,
                                    "5s was measured to leave the radio still holding the session")
        XCTAssertLessThanOrEqual(IcomLANSession.settleAfterClose, 30,
                                 "a reconnect the operator asked for should not feel broken")
    }

    // MARK: - macOS refusing the LAN

    /// The lockout of 2026-09-17.
    ///
    /// macOS pulled AXTerm's local network grant mid-session; all three UDP
    /// flows died with ENOTCONN and every reconnect after it sat unroutable
    /// until the handshake ran out. Reported as a timeout it read as a dead
    /// radio, and sent the operator to check a WLAN that was working.
    func testALocalNetworkDenialIsNamedRatherThanTimedOut() {
        XCTAssertEqual(IcomLANError.denial(for: .localNetworkDenied), .localNetworkDenied)

        let message = IcomLANError.localNetworkDenied.message
        XCTAssertTrue(message.contains("macOS"), message)
        XCTAssertTrue(message.contains("Local Network"), message)
        XCTAssertFalse(message.contains("Network Control"),
                       "this one is not about the radio's settings")
    }

    /// Debugged from Xcode, the app's own Local Network switch is not the
    /// one macOS reads — the responsible process is Xcode. Sending the
    /// operator to AXTerm's switch there is advice that cannot work, and
    /// cost an hour on 2026-09-17 with the switch already turned on.
    func testTheAdviceNamesOnlyTheSwitchWeKnowOf() {
        for debugged in [true, false] {
            let advice = IcomLANError.localNetworkDenialAdvice(debugged: debugged)
            XCTAssertTrue(advice.contains("AXTerm"), advice)
            XCTAssertTrue(advice.contains("Local Network"), advice)
            XCTAssertFalse(advice.contains("Xcode"),
                           "which identity macOS judged is not known, and this message said it "
                           + "was Xcode for half a day on an inference nobody checked")
        }
        XCTAssertTrue(IcomLANError.localNetworkDenialAdvice(debugged: true).contains("debugger"))
    }

    /// A path can be unsatisfied for reasons that really are the network's.
    /// Only the refusal we can act on gets its own message.
    func testOtherUnsatisfiedPathsKeepTheCallersOwnError() {
        XCTAssertNil(IcomLANError.denial(for: nil))
        XCTAssertNil(IcomLANError.denial(for: .notAvailable))
        XCTAssertNil(IcomLANError.denial(for: .wifiDenied))
    }

    // MARK: - What a socket state means to a waiting handshake

    /// The lockout of 2026-09-17, at the level the handler decides it.
    ///
    /// A denied path parks NWConnection in .waiting and reports nothing, so
    /// waiting it out costs the whole handshake window and ends in a
    /// timeout naming the radio. A named refusal has to end the wait.
    func testADeniedPathEndsTheWaitInsteadOfRidingItOut() {
        let waiting = NWConnection.State.waiting(.posix(.ENETDOWN))

        XCTAssertEqual(IcomLANSocketOutcome.of(waiting, denial: .localNetworkDenied),
                       .fail(.localNetworkDenied))
        XCTAssertEqual(IcomLANSocketOutcome.of(waiting, denial: nil), .keepWaiting,
                       "a network that is merely down may yet come up")
    }

    /// A denial explains a dead socket better than the POSIX error does.
    func testAFailedSocketPrefersTheRefusalWeCanName() {
        let failed = NWConnection.State.failed(.posix(.ECONNREFUSED))

        XCTAssertEqual(IcomLANSocketOutcome.of(failed, denial: .localNetworkDenied),
                       .fail(.localNetworkDenied))

        guard case .fail(let fallback) = IcomLANSocketOutcome.of(failed, denial: nil) else {
            return XCTFail("a failed socket is a failure")
        }
        if case .network = fallback {} else {
            XCTFail("with nothing to name, the socket's own error stands: \(fallback)")
        }
    }

    func testReadyAndCancelledSpeakForThemselves() {
        XCTAssertEqual(IcomLANSocketOutcome.of(.ready, denial: nil), .ready)
        XCTAssertEqual(IcomLANSocketOutcome.of(.ready, denial: .localNetworkDenied), .ready,
                       "a socket that came up is up, whatever the path said on the way")
        XCTAssertEqual(IcomLANSocketOutcome.of(.cancelled, denial: nil),
                       .fail(.network("cancelled")))
        XCTAssertEqual(IcomLANSocketOutcome.of(.setup, denial: nil), .keepWaiting)
    }
}
