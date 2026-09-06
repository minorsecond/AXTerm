import XCTest
@testable import AXTerm

/// Frames leave on the channel their session was opened on.
///
/// `SessionKey` has carried a channel since the beginning and every handler
/// threads it through, but the frame builders never took it, so every frame
/// a session produced went out as KISS port 0 whatever the session said. With
/// one TNC nobody could tell. With a multi-port TNC the reply to a SABM heard
/// on port 1 would go out port 0 — the wrong radio.
@MainActor
final class SessionChannelStampTests: XCTestCase {

    private let local = AX25Address(call: "TEST", ssid: 7)
    private let peer = AX25Address(call: "PEER", ssid: 1)

    /// The UA answering a SABM leaves on the port the SABM arrived on.
    func testTheUALeavesOnTheChannelTheSABMArrivedOn() {
        let manager = AX25SessionManager(localCallsign: local)
        let ua = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), channel: 3)
        XCTAssertNotNil(ua)
        XCTAssertEqual(ua?.channel, 3)
    }

    /// The DM for a poll with no session has no session to ask, so it takes
    /// the channel the poll came in on.
    func testTheDMForAStrangerLeavesOnTheChannelThePollArrivedOn() {
        let manager = AX25SessionManager(localCallsign: local)
        let dm = manager.handleInboundRR(from: peer, path: DigiPath(), channel: 5,
                                         nr: 0, pf: true, isCommand: true)
        XCTAssertEqual(dm?.channel, 5)
    }

    /// Port 0 stays port 0: the common case is untouched.
    func testChannelZeroIsUnchanged() {
        let manager = AX25SessionManager(localCallsign: local)
        let ua = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), channel: 0)
        XCTAssertEqual(ua?.channel, 0)
    }

    /// Stamping keeps the frame's identity — it is the same transmission,
    /// not a retry — and is a no-op when nothing changes.
    func testOnChannelKeepsIdentity() {
        let frame = AX25FrameBuilder.buildUA(from: local, to: peer, via: DigiPath())
        let moved = frame.onChannel(2)
        XCTAssertEqual(moved.id, frame.id)
        XCTAssertEqual(moved.channel, 2)
        XCTAssertEqual(moved.encodeAX25(), frame.encodeAX25())
        XCTAssertEqual(frame.onChannel(frame.channel).channel, frame.channel)
    }
}
