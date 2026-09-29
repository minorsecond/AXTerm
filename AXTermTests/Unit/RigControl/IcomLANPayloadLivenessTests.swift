#if os(macOS)
import XCTest
@testable import AXTerm

/// Noticing a radio that is punctual and empty.
///
/// From the operator's log of 2026-09-18. At 00:03:28 the IC-705 stopped
/// serving its serial and audio streams. It kept pinging all three on its own
/// 10 Hz schedule, so every stream stayed fresh, `audio=0.1s control=0.0s`,
/// and the link reported healthy for the next four hours and thirty-one
/// minutes. The CI-V inbound byte counter never advanced past 143,065 and
/// 12,624 commands went unanswered.
///
/// Silence was already measured. What was not measured is the difference
/// between a datagram and something worth sending: a keepalive proves the
/// far end's ping responder is running, and nothing else.
final class IcomLANPayloadLivenessTests: XCTestCase {

    private func stream(_ name: String) -> IcomLANStream {
        IcomLANStream(name: name, queue: DispatchQueue(label: "test"))
    }

    // MARK: - The stamp

    func testAKeepaliveIsNotEvidenceThatTheRadioIsServingUs() {
        let s = stream("audio")
        s.handle(IcomLAN.control(.idle, local: 1, remote: 2))

        XCTAssertGreaterThan(s.lastInboundAt, 0, "a datagram did arrive")
        XCTAssertEqual(s.lastPayloadAt, 0,
                       "an idle is the radio's ping responder, not its content")
    }

    func testSomethingWorthSendingStampsThePayloadClock() {
        let s = stream("audio")
        s.handle(Data([0x10, 0x00, 0x00, 0x00, 0x99, 0x00, 0x01, 0x02,
                       0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A]))

        XCTAssertGreaterThan(s.lastPayloadAt, 0)
    }

    /// The shape of the outage: keepalives forever, content never.
    func testAStreamFedOnlyKeepalivesGoesStaleOnPayloadButNotOnSilence() {
        let s = stream("audio")
        s.beginListening(now: IcomLANStream.now - 600)
        for _ in 0..<100 {
            s.handle(IcomLAN.control(.idle, local: 1, remote: 2))
        }

        XCTAssertLessThan(s.silence ?? .infinity, 1,
                          "the stream is punctual, which is exactly the trap")
        XCTAssertGreaterThan(s.payloadSilence ?? 0, 500,
                             "and it has carried nothing for ten minutes")
    }

    // MARK: - The rule

    func testPayloadSilenceIsJudgedOnlyPastTheLimit() {
        XCTAssertNil(IcomLANLiveness.payloadComplaint(silentFor: 0))
        XCTAssertNil(IcomLANLiveness.payloadComplaint(
            silentFor: IcomLANLiveness.payloadSilenceLimit - 0.01))
        XCTAssertNotNil(IcomLANLiveness.payloadComplaint(
            silentFor: IcomLANLiveness.payloadSilenceLimit))
    }

    /// Total silence is unambiguous; keepalives-without-content is stranger,
    /// and its false positive would drop a radio that is working. It gets more
    /// rope.
    func testTheQuietLimitIsMoreGenerousThanTheSilenceLimit() {
        XCTAssertGreaterThan(IcomLANLiveness.payloadSilenceLimit,
                             IcomLANLiveness.silenceLimit)
    }

    /// The complaint has to say which of the two it is, because they need
    /// different fixes: one is a network that stopped carrying, the other is a
    /// radio that stopped serving a session it is still maintaining.
    func testTheComplaintSaysTheSessionIsUpAndUnused() {
        let why = IcomLANLiveness.payloadComplaint(silentFor: 60) ?? ""
        XCTAssertTrue(why.contains("still answering"))
        XCTAssertTrue(why.contains("no audio"))
    }

    // MARK: - Reconnect

    func testAReconnectDoesNotInheritThePreviousSessionsPayloadStamp() {
        let s = stream("audio")
        s.handle(Data([0x10, 0x00, 0x00, 0x00, 0x99, 0x00, 0x01, 0x02,
                       0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A]))
        XCTAssertGreaterThan(s.lastPayloadAt, 0)

        s.disconnect()

        XCTAssertEqual(s.lastPayloadAt, 0)
        XCTAssertNil(s.payloadSilence,
                     "a stream that has heard nothing this session has nothing to judge")
    }

    // MARK: - Cadence

    /// Measured from a capture of a client that holds this radio indefinitely
    /// (2026-09-18): 10 Hz pings on every stream, idle on control at 0.5 s.
    /// Ours was three seconds, thirty times quieter, and the streams we keep
    /// quietest are the ones that stopped being served.
    func testKeepaliveCadenceMatchesWhatWasMeasuredOnTheWire() {
        XCTAssertEqual(IcomLANStream.pingInterval, 0.1, accuracy: 0.0001)
        XCTAssertEqual(IcomLANStream.idleInterval, 0.5, accuracy: 0.0001)
    }
}
#endif
