import XCTest
@testable import AXTerm

/// Frames leave on the radio their session was opened on.
///
/// `SessionKey` has carried the dimension since the beginning (as a KISS
/// channel that was always 0) and every handler threads it through, but the
/// frame builders never took it, so every frame a session produced went out
/// on whatever the engine's one link was. With several radios the reply to a
/// SABM heard on the IC-705 must leave by the IC-705.
@MainActor
final class SessionRadioStampTests: XCTestCase {

    private let local = AX25Address(call: "TEST", ssid: 7)
    private let peer = AX25Address(call: "PEER", ssid: 1)
    private let ic705 = RadioID(rawValue: "ic705")

    /// The UA answering a SABM is bound to the radio the SABM arrived on.
    func testTheUALeavesOnTheRadioTheSABMArrivedOn() {
        let manager = AX25SessionManager(localCallsign: local)
        let ua = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: ic705)
        XCTAssertNotNil(ua)
        XCTAssertEqual(ua?.radio, ic705)
    }

    /// The DM for a poll with no session has no session to ask, so it takes
    /// the radio the poll came in on.
    func testTheDMForAStrangerLeavesOnTheRadioThePollArrivedOn() {
        let manager = AX25SessionManager(localCallsign: local)
        let dm = manager.handleInboundRR(from: peer, path: DigiPath(), radio: ic705,
                                         nr: 0, pf: true, isCommand: true)
        XCTAssertEqual(dm?.radio, ic705)
    }

    /// One peer on two radios is two sessions: the same callsign heard by two
    /// antennas is two links.
    func testOnePeerOnTwoRadiosIsTwoSessions() {
        let manager = AX25SessionManager(localCallsign: local)
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: ic705)
        XCTAssertNotNil(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        XCTAssertNotNil(manager.existingSession(for: peer, path: DigiPath(), radio: ic705))
        XCTAssertNotEqual(manager.existingSession(for: peer, path: DigiPath(), radio: .primary)?.key,
                          manager.existingSession(for: peer, path: DigiPath(), radio: ic705)?.key)
    }

    /// Callers that predate radios still compile and land on the primary.
    func testTheDefaultIsThePrimaryRadio() {
        let manager = AX25SessionManager(localCallsign: local)
        let ua = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        XCTAssertEqual(ua?.radio, .primary)
        XCTAssertEqual(SessionKey(destination: peer, path: DigiPath()).radio, .primary)
    }

    /// Stamping keeps the frame's identity — it is the same transmission,
    /// not a retry — and is a no-op when nothing changes.
    func testOnRadioKeepsIdentity() {
        let frame = AX25FrameBuilder.buildUA(from: local, to: peer, via: DigiPath())
        let moved = frame.onRadio(ic705)
        XCTAssertEqual(moved.id, frame.id)
        XCTAssertEqual(moved.radio, ic705)
        XCTAssertEqual(moved.encodeAX25(), frame.encodeAX25())
        XCTAssertEqual(frame.onRadio(frame.radio).radio, frame.radio)
    }

    /// A frame written before radios existed decodes onto the primary.
    func testAnOldFrameDecodesOntoThePrimary() throws {
        let frame = AX25FrameBuilder.buildUA(from: local, to: peer, via: DigiPath())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as! [String: Any]
        json.removeValue(forKey: "radio")
        json["channel"] = 0
        let decoded = try JSONDecoder().decode(OutboundFrame.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.radio, .primary)
        XCTAssertEqual(decoded.id, frame.id)
    }
}
