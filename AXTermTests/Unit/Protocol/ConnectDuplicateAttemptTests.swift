import XCTest
@testable import AXTerm

/// One click, one connect attempt.
///
/// Clicking a station repeatedly used to put a frame on the air each time.
/// The connected/connecting guards covered the classic flow, but an XID
/// negotiation leaves the session `.disconnected` — it has not sent SABM yet —
/// so nothing caught a second attempt during the whole negotiation window.
@MainActor
final class ConnectDuplicateAttemptTests: XCTestCase {

    private func manager(negotiating: Bool) -> AX25SessionManager {
        let manager = AX25SessionManager(
            localCallsign: AX25Address(call: "K0EPI", ssid: 7))
        manager.negotiateV22 = negotiating
        return manager
    }

    private let peer = AX25Address(call: "KB5YZB", ssid: 7)

    /// The regression. With XID on, the first call sends the negotiation and
    /// every further call used to send another.
    func testRepeatedConnectsDuringNegotiationSendOneFrame() {
        let sut = manager(negotiating: true)
        XCTAssertNotNil(sut.connect(to: peer), "the first attempt should go out")
        for _ in 0..<5 {
            XCTAssertNil(sut.connect(to: peer),
                         "a negotiation in flight is a connect in flight")
        }
    }

    /// The classic flow, which was already guarded — kept so it stays that way.
    func testRepeatedConnectsWhileConnectingSendOneFrame() {
        let sut = manager(negotiating: false)
        XCTAssertNotNil(sut.connect(to: peer))
        for _ in 0..<5 {
            XCTAssertNil(sut.connect(to: peer))
        }
    }

    /// Different peers are different conversations.
    func testAnotherPeerIsNotBlocked() {
        let sut = manager(negotiating: true)
        XCTAssertNotNil(sut.connect(to: peer))
        XCTAssertNotNil(sut.connect(to: AX25Address(call: "K0NTS", ssid: 10)))
    }
}
