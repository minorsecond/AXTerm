#if os(macOS)
import XCTest
@testable import AXTerm

/// Noticing that the radio has gone away.
///
/// From the operator's log of 2026-09-09: at 11:48:49Z macOS refused the app
/// local-network access on `en7` and the three UDP sockets to 192.168.3.34
/// died. The IC-705 dropped the session and stopped showing a client. AXTerm
/// went on reporting the radio as connected for the next two hours and never
/// received another frame from it.
///
/// UDP is why this needs saying out loud: there is no connection to lose, so a
/// radio that stops answering produces no error at all. The only evidence is
/// silence, and silence has to be measured.
final class IcomLANLivenessTests: XCTestCase {

    // MARK: - The rule

    /// The radio pings us several times a second and, once audio is running,
    /// sends a packet every few milliseconds. A whole second of quiet is
    /// already odd; the limit is set well past that so a busy Mac or a brief
    /// Wi-Fi stumble cannot be mistaken for a radio that has gone.
    func testASilenceLongerThanTheLimitIsDeath() {
        XCTAssertNil(IcomLANLiveness.complaint(silentFor: 0))
        XCTAssertNil(IcomLANLiveness.complaint(silentFor: IcomLANLiveness.silenceLimit - 0.01))
        XCTAssertNotNil(IcomLANLiveness.complaint(silentFor: IcomLANLiveness.silenceLimit))
    }

    /// The message has to be something an operator can act on. "Transport
    /// error 57" names the symptom; this names the radio and what to check.
    func testTheComplaintSaysWhatHappenedAndWhatToCheck() throws {
        let why = try XCTUnwrap(IcomLANLiveness.complaint(silentFor: 12))
        XCTAssertTrue(why.contains("stopped"), why)
        XCTAssertTrue(why.lowercased().contains("network"), "point at the cause: \(why)")
    }

    /// A session that has never heard anything is not yet silent — the
    /// handshake has its own timeout, and a zero stamp must not read as an
    /// infinite silence the moment the watchdog starts.
    func testAnUnstampedSessionIsNotDeclaredDead() {
        XCTAssertNil(IcomLANLiveness.complaint(lastInboundAt: 0, now: 5_000_000))
    }

    // MARK: - What counts as a sign of life

    /// The trap this bug is made of. `handle` returns early for pings and
    /// idles — they are the *most* common inbound packets and the only ones a
    /// radio sends when nothing else is happening. A watchdog stamped from
    /// `onPacket` would therefore call a perfectly healthy but quiet radio
    /// dead. Every datagram counts, whatever it is.
    func testAPingKeepsTheSessionAlive() {
        let stream = IcomLANStream(name: "control", queue: DispatchQueue(label: "test"))
        XCTAssertEqual(stream.lastInboundAt, 0, "nothing heard yet")

        var delivered = 0
        stream.onPacket = { _ in delivered += 1 }
        stream.handle(IcomLAN.ping(sequence: 7, local: 1, remote: 2, reply: true, id: [0, 0, 0, 6]))

        XCTAssertEqual(delivered, 0, "a ping is not a packet the session sees")
        XCTAssertGreaterThan(stream.lastInboundAt, 0, "but it is proof the radio is there")
    }

    /// Which streams may be judged. Control and audio both carry traffic
    /// continuously — the radio pings control several times a second and audio
    /// is a packet every few milliseconds — so silence there means something.
    /// CI-V is different: it flows only when there is something to say, and a
    /// quiet serial stream is the normal state of a radio nobody is tuning.
    /// Watching it would drop working links.
    func testOnlyTheStreamsThatAreAlwaysBusyAreJudged() {
        XCTAssertEqual(IcomLANLiveness.watchedStreams, ["control", "audio"],
                       "CI-V is quiet by nature; failing on its silence is a false alarm")
    }

    /// The regression this watchdog caused, one day after it was written.
    ///
    /// `IcomLANStream` objects are reused across connect/disconnect cycles —
    /// `connect()` says so, and resets every per-session counter it knows
    /// about. `lastInboundAt` was not on that list, so it survived into the
    /// next session, and the first liveness tick of a freshly connected radio
    /// measured its silence from the *previous* session's last packet.
    ///
    /// From the operator's log of 2026-09-09: the IC-705 dropped the session
    /// at 13:04:30 (its own doing). Every reconnect after that connected and
    /// died again exactly one second later — the watchdog's first tick —
    /// leaving CI-V answering nothing and the modem reporting "the radio's
    /// network session is not up". Control is stamped continuously through
    /// the login, so it was audio's stale stamp that decided it: the watch
    /// takes the quieter of the two.
    func testAStreamThatReconnectedHasNotHeardThePreviousSession() {
        let stream = IcomLANStream(name: "audio", queue: DispatchQueue(label: "test"))
        stream.handle(IcomLAN.control(.idle, local: 1, remote: 2))
        XCTAssertNotNil(stream.silence, "heard something in this session")

        stream.disconnect()

        XCTAssertEqual(stream.lastInboundAt, 0,
                       "a disconnected stream has heard nothing; the next session "
                       + "must not inherit this one's last packet")
        XCTAssertNil(stream.silence,
                     "silence measured across a reconnect kills the new session "
                     + "on the watchdog's first tick")
    }

    /// And the rule downstream of it: no stamp means no verdict. A session
    /// that has just connected and not yet been spoken to is not silent —
    /// the handshake has its own timeout.
    func testASessionThatHasHeardNothingYetIsNotDeclaredDead() {
        XCTAssertNil(IcomLANLiveness.complaint(lastInboundAt: 0,
                                               now: IcomLANStream.now + 3600))
    }

    func testAnIdleKeepsTheSessionAlive() {
        let stream = IcomLANStream(name: "control", queue: DispatchQueue(label: "test"))
        stream.handle(IcomLAN.control(.idle, local: 1, remote: 2))
        XCTAssertGreaterThan(stream.lastInboundAt, 0)
    }
}
#endif
