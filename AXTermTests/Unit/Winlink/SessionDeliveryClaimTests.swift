import XCTest
@testable import AXTerm

/// The delivery-claim mechanism must give a protocol conversation
/// exclusive access to a session's bytes: while claimed, neither the
/// terminal (`onDataReceived`) nor AXDP reassembly
/// (`onDataDeliveredForReassembly`) may see them.
@MainActor
final class SessionDeliveryClaimTests: XCTestCase {

    private func makeManager() -> AX25SessionManager {
        let local = AX25Address(call: "K0EPI", ssid: 2)
        return AX25SessionManager(localCallsign: local)
    }

    private func establishSession(_ manager: AX25SessionManager, peer: String = "KE7XO-10") -> AX25Session {
        let parsed = CallsignNormalizer.parse(peer)
        let remote = AX25Address(call: parsed.call, ssid: parsed.ssid)
        // Peer initiates: inbound SABM creates and connects the session.
        _ = manager.handleInboundSABM(from: remote, to: manager.localCallsign, path: DigiPath(), channel: 0)
        let session = manager.existingSession(for: remote)!
        XCTAssertEqual(session.state, .connected)
        return session
    }

    private func deliverIFrame(_ manager: AX25SessionManager, session: AX25Session, payload: Data, ns: Int) {
        _ = manager.handleInboundIFrame(
            from: session.remoteAddress,
            path: DigiPath(),
            channel: 0,
            ns: ns,
            nr: 0,
            pf: false,
            payload: payload)
    }

    func testUnclaimedSessionDeliversToRegularCallbacks() {
        let manager = makeManager()
        var terminalData = Data()
        var reassemblyData = Data()
        manager.onDataReceived = { _, data in terminalData.append(data) }
        manager.onDataDeliveredForReassembly = { _, data in reassemblyData.append(data) }

        let session = establishSession(manager)
        deliverIFrame(manager, session: session, payload: Data("hello\r".utf8), ns: 0)

        XCTAssertEqual(terminalData, Data("hello\r".utf8))
        XCTAssertEqual(reassemblyData, Data("hello\r".utf8))
    }

    func testClaimedSessionBypassesTerminalAndAXDP() {
        let manager = makeManager()
        var terminalData = Data()
        var reassemblyData = Data()
        var claimedData = Data()
        manager.onDataReceived = { _, data in terminalData.append(data) }
        manager.onDataDeliveredForReassembly = { _, data in reassemblyData.append(data) }

        let session = establishSession(manager)
        let claim = manager.claimDelivery(for: session.key) { _, data in claimedData.append(data) }
        XCTAssertNotNil(claim)

        // Binary bytes (SOH/STX) that would confuse both consumers.
        let payload = Data([0x01, 0x04, 0x74, 0x00, 0x30, 0x00, 0x02, 0x03, 0xaa, 0xbb, 0xcc])
        deliverIFrame(manager, session: session, payload: payload, ns: 0)

        XCTAssertEqual(claimedData, payload)
        XCTAssertTrue(terminalData.isEmpty, "terminal must not see claimed bytes")
        XCTAssertTrue(reassemblyData.isEmpty, "AXDP reassembly must not see claimed bytes")
    }

    func testReleaseRestoresRegularDelivery() {
        let manager = makeManager()
        var terminalData = Data()
        manager.onDataReceived = { _, data in terminalData.append(data) }

        let session = establishSession(manager)
        let claim = manager.claimDelivery(for: session.key) { _, _ in }!
        deliverIFrame(manager, session: session, payload: Data("claimed".utf8), ns: 0)
        XCTAssertTrue(terminalData.isEmpty)

        manager.releaseDelivery(claim)
        deliverIFrame(manager, session: session, payload: Data("normal".utf8), ns: 1)
        XCTAssertEqual(terminalData, Data("normal".utf8))
    }

    func testSecondClaimIsRefused() {
        let manager = makeManager()
        let session = establishSession(manager)
        let first = manager.claimDelivery(for: session.key) { _, _ in }
        XCTAssertNotNil(first)
        let second = manager.claimDelivery(for: session.key) { _, _ in }
        XCTAssertNil(second, "a session's byte stream has exactly one owner")

        manager.releaseDelivery(first!)
        XCTAssertNotNil(manager.claimDelivery(for: session.key) { _, _ in })
    }

    func testStaleClaimCannotReleaseNewClaim() {
        let manager = makeManager()
        let session = establishSession(manager)
        let first = manager.claimDelivery(for: session.key) { _, _ in }!
        manager.releaseDelivery(first)
        let second = manager.claimDelivery(for: session.key) { _, _ in }!

        // Releasing with the stale token must not free the new claim.
        manager.releaseDelivery(first)
        XCTAssertTrue(manager.hasDeliveryClaim(for: session.key))
        manager.releaseDelivery(second)
        XCTAssertFalse(manager.hasDeliveryClaim(for: session.key))
    }

    func testClaimStateHandlerObservesDisconnect() {
        let manager = makeManager()
        let session = establishSession(manager)

        var transitions = [AX25SessionState]()
        let claim = manager.claimDelivery(
            for: session.key,
            handler: { _, _ in },
            stateHandler: { _, _, newState in transitions.append(newState) })
        XCTAssertNotNil(claim)

        // Peer sends DISC — session should disconnect and notify the claim.
        _ = manager.handleInboundDISC(
            from: session.remoteAddress, path: DigiPath(), channel: 0)
        XCTAssertTrue(transitions.contains(.disconnected), "transitions: \(transitions)")
    }

    /// A claim must not outlive its session. Claim holders are captured
    /// weakly, and a protocol runner routinely drops its transport in the
    /// seconds between sending DISC and the UA arriving — leaving the
    /// stale claim to refuse every later connect as "session busy".
    func testDisconnectReleasesTheClaimEvenIfTheHolderIsGone() {
        let manager = makeManager()
        let session = establishSession(manager)

        // A holder that has already been deallocated: the state handler
        // captures nothing and cannot release anything itself.
        _ = manager.claimDelivery(
            for: session.key,
            handler: { _, _ in },
            stateHandler: { _, _, _ in })
        XCTAssertTrue(manager.hasDeliveryClaim(for: session.key))

        _ = manager.handleInboundDISC(
            from: session.remoteAddress, path: DigiPath(), channel: 0)

        XCTAssertFalse(manager.hasDeliveryClaim(for: session.key),
                       "a disconnected session must not keep its delivery claim")

        // And the peer is reachable again rather than permanently busy.
        XCTAssertNotNil(manager.claimDelivery(for: session.key) { _, _ in },
                        "a fresh exchange must be able to claim the link again")
    }

    func testRemovingASessionReleasesItsClaim() {
        let manager = makeManager()
        let session = establishSession(manager)
        _ = manager.claimDelivery(for: session.key) { _, _ in }

        manager.removeSession(session)

        XCTAssertFalse(manager.hasDeliveryClaim(for: session.key))
    }
}
