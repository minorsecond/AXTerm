//
//  XIDNegotiationTests.swift
//  AXTermTests
//
//  AX.25 2.2 parameter negotiation (§6.3.2): before the first SABM to an
//  unknown peer, send an XID command offering SREJ and our N1/k. A 2.2
//  peer answers XID and the link runs with selective reject and agreed
//  limits; a pre-2.2 peer answers FRMR ("use defaults", per the spec —
//  never an error), and a silent peer costs one RTO once — the outcome is
//  cached per callsign so later connects go straight to SABM.
//
//  Negotiation is opt-in on the manager (`negotiateV22`), enabled by the
//  app through settings; bare managers and the test harnesses keep the
//  classic connect flow.
//

import XCTest
@testable import AXTerm

@MainActor
final class XIDNegotiationTests: XCTestCase {

    private var manager: AX25SessionManager!
    private var clock: AX25VirtualClock!
    private var sent: [OutboundFrame] = []
    private let peer = AX25Address(call: "W0ARP", ssid: 10)

    override func setUp() {
        super.setUp()
        clock = AX25VirtualClock()
        manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 7), clock: clock)
        manager.defaultConfig = AX25SessionConfig(
            windowSize: 4, paclen: 128, rtoMin: 2.0, rtoMax: 8.0, initialRto: 2.0)
        manager.negotiateV22 = true
        sent = []
        manager.onSendFrame = { [weak self] frame in self?.sent.append(frame) }
    }

    override func tearDown() {
        manager = nil
        clock = nil
        super.tearDown()
    }

    private func xidResponse(srej: Bool, n1: Int? = nil, k: Int? = nil) -> Data {
        var params = AX25XIDParameters()
        params.supportsSREJ = srej
        params.iFieldLengthRx = n1
        params.windowSizeRx = k
        return params.encoded(isCommand: false)
    }

    // MARK: - Outbound negotiation

    func testFirstConnectSendsXIDCommandNotSABM() {
        let frame = manager.connect(to: peer, path: DigiPath(), channel: 0)
        XCTAssertEqual(frame?.displayInfo, "XID")
        XCTAssertEqual(frame?.controlByte, 0xBF, "XID command with P=1")
        XCTAssertFalse(sent.contains { $0.displayInfo == "SABM" },
                       "SABM waits for the XID answer")
    }

    func testXIDResponseEnablesSREJAndMinimumsThenSABM() {
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        let responses = manager.handleInboundXID(
            from: peer, path: DigiPath(), channel: 0,
            info: xidResponse(srej: true, n1: 64, k: 2), isCommand: false, pf: true)
        XCTAssertTrue(responses.isEmpty, "an XID response draws no reply")

        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" }, "SABM follows the answer")
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)
        XCTAssertTrue(session.stateMachine.config.srejEnabled)
        XCTAssertEqual(session.stateMachine.config.windowSize, 2, "k = min(ours 4, theirs 2)")
        XCTAssertEqual(session.stateMachine.config.paclen, 64, "paclen = min(ours 128, their N1 64)")
    }

    func testPeerWithoutSREJGetsPlainGoBackN() {
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        _ = manager.handleInboundXID(
            from: peer, path: DigiPath(), channel: 0,
            info: xidResponse(srej: false), isCommand: false, pf: true)
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)
        XCTAssertFalse(session.stateMachine.config.srejEnabled)
        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" })
    }

    /// §6.3.2: pre-2.2 implementations answer XID with FRMR. That is the
    /// documented "no" — connect proceeds with defaults, never fails.
    func testFRMRFallsBackToPlainSABM() {
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        manager.handleInboundFRMRDuringNegotiation(from: peer, channel: 0)

        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" })
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)
        XCTAssertFalse(session.stateMachine.config.srejEnabled)
    }

    /// The other pre-2.2 answer, and the one BPQ actually gives: DM.
    ///
    /// A node with no XID implementation holds no link to us, so it says
    /// "no such link". Before this was handled the DM landed on a session
    /// still in `.disconnected`, the state machine no-opped, and the
    /// connect sat out its whole RTO anyway: on 2026-08-27 DRLNOD answered
    /// in 2.1 s and AXTerm did not send SABM until 8 s had passed.
    func testDMFallsBackToPlainSABMWithoutWaitingOutTheRTO() {
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        XCTAssertFalse(sent.contains { $0.displayInfo == "SABM" })

        XCTAssertTrue(manager.handleInboundDMDuringNegotiation(from: peer, channel: 0),
                      "the DM belongs to the negotiation and is consumed by it")

        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" },
                      "the answer arrived; there is nothing left to wait for")
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)
        XCTAssertFalse(session.stateMachine.config.srejEnabled)
        XCTAssertEqual(session.state, .connecting)
    }

    /// The SABM the negotiation just sent must survive. A DM consumed here
    /// and *also* run through normal handling would reach a `.connecting`
    /// session as "connection refused" and cancel the connect it started.
    func testDMOutsideNegotiationIsNotConsumed() {
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        _ = manager.handleInboundDMDuringNegotiation(from: peer, channel: 0)

        XCTAssertFalse(manager.handleInboundDMDuringNegotiation(from: peer, channel: 0),
                       "negotiation is over; a later DM is a real refusal")
    }

    func testSilentPeerTimesOutOnceAndIsCached() {
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        XCTAssertFalse(sent.contains { $0.displayInfo == "SABM" })

        clock.advance(by: 3.0)  // past the 2.0 s RTO
        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" },
                      "timeout falls back to the classic connect")

        // Tear down and reconnect: the peer is now known pre-2.2 — no XID.
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)
        manager.forceDisconnect(session: session)
        manager.removeSession(session)
        sent = []
        let frame = manager.connect(to: peer, path: DigiPath(), channel: 0)
        XCTAssertEqual(frame?.displayInfo, "SABM", "one RTO paid once, not per connect")
    }

    func testSecondConnectAfterSuccessfulXIDSkipsStraightToSABMWithSREJ() {
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        _ = manager.handleInboundXID(
            from: peer, path: DigiPath(), channel: 0,
            info: xidResponse(srej: true), isCommand: false, pf: true)
        let first = manager.session(for: peer, path: DigiPath(), channel: 0)
        manager.forceDisconnect(session: first)
        manager.removeSession(first)
        sent = []

        let frame = manager.connect(to: peer, path: DigiPath(), channel: 0)
        XCTAssertEqual(frame?.displayInfo, "SABM", "capabilities are cached per callsign")
        let session = manager.session(for: peer, path: DigiPath(), channel: 0)
        XCTAssertTrue(session.stateMachine.config.srejEnabled)
    }

    /// Field capture 2026-08-24, first on-air XID: the Winlink transport
    /// calls connect() and then awaits the outcome — but during the XID
    /// phase the session still reads `.disconnected`, which the awaiter
    /// took for "refused" milliseconds after the XID went out. The user
    /// saw "connect refused" followed by the link connecting anyway.
    /// While negotiation is pending, the outcome must stay undecided.
    func testAwaitOutcomeDoesNotReadPendingNegotiationAsRefused() async {
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        let key = SessionKey(destination: peer, path: DigiPath(), channel: 0)

        let outcomeTask = Task { [manager] in
            await manager!.awaitConnectionOutcome(key: key, timeout: 3.0)
        }
        // Give the awaiter time for its first poll — the one that used to
        // return .refused instantly.
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Peer answers XID (pre-2.2 peers would FRMR here instead — same
        // resolution path), SABM goes out, UA completes the link.
        _ = manager.handleInboundXID(
            from: peer, path: DigiPath(), channel: 0,
            info: xidResponse(srej: true), isCommand: false, pf: true)
        manager.handleInboundUA(from: peer, path: DigiPath(), channel: 0)

        let outcome = await outcomeTask.value
        XCTAssertEqual(outcome, .connected,
                       "a pending XID is a connection in progress, not a refusal")
    }

    func testNegotiationDisabledConnectsClassically() {
        manager.negotiateV22 = false
        let frame = manager.connect(to: peer, path: DigiPath(), channel: 0)
        XCTAssertEqual(frame?.displayInfo, "SABM")
    }

    // MARK: - Inbound negotiation (we are the responder)

    func testInboundXIDCommandDrawsAResponseSelectingSREJ() {
        var offer = AX25XIDParameters()
        offer.supportsSREJ = true
        let responses = manager.handleInboundXID(
            from: peer, path: DigiPath(), channel: 0,
            info: offer.encoded(isCommand: true), isCommand: true, pf: true)

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.displayInfo, "XID")
        XCTAssertEqual(responses.first?.controlByte, 0xBF, "response mirrors F=1")
        let parsed = AX25XIDParameters.parse(responses.first?.payload ?? Data())
        XCTAssertEqual(parsed?.supportsSREJ, true, "we accept the offered SREJ")

        // The SABM that follows creates a session that honors the agreement.
        _ = manager.handleInboundSABM(from: peer, to: manager.localCallsign, path: DigiPath(), channel: 0)
        let session = manager.existingSession(for: peer)!
        XCTAssertTrue(session.stateMachine.config.srejEnabled)
    }

    func testInboundXIDOfferWithoutSREJIsAnsweredWithoutSREJ() {
        var offer = AX25XIDParameters()
        offer.supportsSREJ = false
        let responses = manager.handleInboundXID(
            from: peer, path: DigiPath(), channel: 0,
            info: offer.encoded(isCommand: true), isCommand: true, pf: true)
        let parsed = AX25XIDParameters.parse(responses.first?.payload ?? Data())
        XCTAssertEqual(parsed?.supportsSREJ, false,
                       "never select an option the peer did not offer")

        _ = manager.handleInboundSABM(from: peer, to: manager.localCallsign, path: DigiPath(), channel: 0)
        XCTAssertFalse(manager.existingSession(for: peer)!.stateMachine.config.srejEnabled)
    }

    func testMalformedXIDIsTreatedAsUnsupported() {
        _ = manager.connect(to: peer, path: DigiPath(), channel: 0)
        _ = manager.handleInboundXID(
            from: peer, path: DigiPath(), channel: 0,
            info: Data([0xDE, 0xAD]), isCommand: false, pf: true)
        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" },
                      "garbage in the answer still must not strand the connect")
        XCTAssertFalse(manager.session(for: peer, path: DigiPath(), channel: 0)
            .stateMachine.config.srejEnabled)
    }
}
