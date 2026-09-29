import XCTest
@testable import AXTerm

/// What this station says when a peer opens with AX.25 2.2.
///
/// Reported from the air on 2026-09-19: a v2.2 peer's SABME was accepted and
/// its XID was never answered, so the peer sat retrying XID with P set against
/// a station that had agreed to a mode it could not run. The operator had to
/// force v2.0 to get a link at all.
@MainActor
final class AX25VersionNegotiationTests: XCTestCase {

    private let local = AX25Address(call: "K0EPI", ssid: 5)
    private let peer = AX25Address(call: "K0EPI", ssid: 7)

    private func manager() -> AX25SessionManager {
        AX25SessionManager(localCallsign: local)
    }

    // MARK: - SABME

    /// Extended mode makes every I- and S-frame control field two bytes, and
    /// the inbound KISS decode is not session-aware, so it cannot find the end
    /// of one. The transmission spec says modulo 128 is deliberately not
    /// offered; agreeing to it anyway was the bug.
    func testSABMEIsRefusedWithDM() throws {
        let reply = try XCTUnwrap(manager().handleInboundSABM(
            from: peer, to: local, path: DigiPath(), radio: .primary, extended: true))
        XCTAssertEqual(reply.displayInfo, "DM", "SABME must be refused, not accepted")
    }

    /// Plain SABM is modulo 8 and is what this station runs, so it still gets
    /// a UA. A fix that refused both would have taken the link away entirely.
    func testPlainSABMIsStillAccepted() throws {
        let reply = try XCTUnwrap(manager().handleInboundSABM(
            from: peer, to: local, path: DigiPath(), radio: .primary, extended: false))
        XCTAssertEqual(reply.displayInfo, "UA")
    }

    /// Refusing must not leave a session behind. A peer that falls back to
    /// SABM has to meet a clean slate, not the carcass of the mode we turned
    /// down.
    func testRefusingSABMELeavesNoSession() {
        let m = manager()
        _ = m.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary, extended: true)
        XCTAssertTrue(m.sessions.isEmpty, "a refused SABME must not open a session")
    }

    /// The F bit of a refusal mirrors the P bit of the request.
    func testTheRefusalMirrorsTheRequestsPollBit() throws {
        let reply = try XCTUnwrap(manager().handleInboundSABM(
            from: peer, to: local, path: DigiPath(), radio: .primary, extended: true, pf: false))
        XCTAssertEqual(reply.controlByte, 0x0F, "DM with F clear")
    }

    // MARK: - XID

    /// An XID command draws a response. The spec is explicit: "an XID command
    /// draws a response selecting the intersection of the offer and our
    /// capabilities".
    func testAnXIDCommandIsAnswered() {
        let out = manager().handleInboundXID(
            from: peer, path: DigiPath(), radio: .primary,
            info: AX25XIDParameters().encoded(isCommand: true), isCommand: true, pf: true)
        XCTAssertEqual(out.count, 1, "an XID command must be answered")
        XCTAssertEqual(out.first?.displayInfo, "XID")
    }

    /// An XID *response* is the end of an exchange and draws nothing. This is
    /// the branch a misclassified command fell into, which is why the peer
    /// heard silence.
    func testAnXIDResponseDrawsNoReply() {
        let out = manager().handleInboundXID(
            from: peer, path: DigiPath(), radio: .primary,
            info: AX25XIDParameters().encoded(isCommand: true), isCommand: false, pf: true)
        XCTAssertTrue(out.isEmpty)
    }

    /// A peer bug must not strand the exchange: a malformed information field
    /// still draws an answer rather than silence.
    func testAMalformedXIDCommandIsStillAnswered() {
        let out = manager().handleInboundXID(
            from: peer, path: DigiPath(), radio: .primary,
            info: Data([0xFF, 0x00, 0x01]), isCommand: true, pf: true)
        XCTAssertEqual(out.count, 1, "a parse failure must not become silence")
    }
}
