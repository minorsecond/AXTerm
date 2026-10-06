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
        // Isolated: the persistent XID memory would otherwise carry a
        // verdict remembered by an earlier test (or an earlier run) into
        // this one, and "first connect probes with XID" stops being true.
        manager.xidMemory = XIDAnswerMemory(
            defaults: TestDefaults.make("XIDNegotiationTests"))
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
        let frame = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(frame?.displayInfo, "XID")
        XCTAssertEqual(frame?.controlByte, 0xBF, "XID command with P=1")
        XCTAssertFalse(sent.contains { $0.displayInfo == "SABM" },
                       "SABM waits for the XID answer")
    }

    /// The first T1 of a link covers our own key-up (AX.25 2.2 §6.7.1.1),
    /// and a sound modem only knows its key-up once it has transmitted. The
    /// session is made before the XID goes out, so the SABM's T1 must be
    /// worked out again with what the XID measured. Smoke run 2026-10-03-1,
    /// issue 59: the first connect after a launch ran T1 at the configured
    /// 3 s against a 4.6 s round trip, and the SABM went out twice.
    func testTheSABMsFirstT1UsesTheKeyUpTheXIDMeasured() {
        manager.defaultConfig = AX25SessionConfig(windowSize: 4, paclen: 128, initialRto: 3.0)
        var keyUp: (ours: Double, peer: Double)? = nil      // nothing measured yet
        manager.keyUpSeconds = { _ in keyUp }
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        let session = manager.existingSession(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session?.timers.rto ?? -1, 3.0, accuracy: 0.01, "the configured T1, as before")

        keyUp = (ours: 3.0, peer: 0.8)                      // the XID keyed the radio
        _ = manager.handleInboundXID(from: peer, path: DigiPath(), radio: .primary,
                                     info: xidResponse(srej: true), isCommand: false, pf: true)
        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" })
        let frameCeiling = session?.stateMachine.config.paclenCeiling ?? 0
        let expected = AX25SessionTimers.initialSRT(t1Setting: 3.0, digipeaters: 0, maxFrameBytes: frameCeiling,
                                                    keyUpSeconds: 3.0, peerKeyUpSeconds: 0.8)
        XCTAssertGreaterThan(expected, 3.0)
        XCTAssertEqual(session?.timers.rto ?? -1, expected, accuracy: 0.01,
                       "the SABM's T1 covers the round trip the radio actually has")
        XCTAssertEqual(session?.stateMachine.config.keyUpSeconds ?? -1, 3.0, accuracy: 0.01,
                       "and T1 starts when the SABM has actually left the radio")
    }

    func testALearnedT1IsNotReplacedByTheEstimate() {
        manager.defaultConfig = AX25SessionConfig(windowSize: 4, paclen: 128, initialRto: 3.0,
                                                  learnedPathRto: 9.0)
        var keyUp: (ours: Double, peer: Double)? = nil
        manager.keyUpSeconds = { _ in keyUp }
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        keyUp = (ours: 3.0, peer: 0.8)
        _ = manager.handleInboundXID(from: peer, path: DigiPath(), radio: .primary,
                                     info: xidResponse(srej: true), isCommand: false, pf: true)
        let session = manager.existingSession(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session?.timers.rto ?? -1, 9.0, accuracy: 0.01,
                       "this route's own measured T1 beats any estimate")
    }

    /// A peer that answered DM or FRMR in a previous launch already told
    /// us its firmware generation — the probe is skipped and the connect
    /// goes straight to SABM instead of re-spending a frame and an RTO.
    func testARememberedRejectionSkipsTheProbeEntirely() {
        manager.rememberXIDAnswer(peer: peer.display, unsupported: true)
        let frame = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(frame?.displayInfo, "SABM",
                       "the answer is remembered; the question is not re-asked")
    }

    /// The memory itself is written by the negotiation's answers: a DM
    /// during this launch means no probe next launch.
    func testADMAnswerWritesTheMemory() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        manager.handleInboundDMDuringNegotiation(from: peer, radio: .primary)
        XCTAssertTrue(manager.xidMemory.isKnownUnsupported(peer.display))
    }

    /// An attempt given up while its XID is out must stay given up: the
    /// answer arriving later used to send the SABM anyway, and the link came
    /// up behind the Auto ladder's back while its next rung dialed the same
    /// station under another address (smoke run 2026-10-03-1, issue 88).
    func testAnAbandonedConnectSendsNoSABMWhenTheXIDAnswerArrives() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertTrue(manager.isNegotiating(key: session.key))
        manager.forceDisconnect(session: session)
        XCTAssertFalse(manager.isNegotiating(key: session.key))

        sent = []
        _ = manager.handleInboundXID(
            from: peer, path: DigiPath(), radio: .primary,
            info: xidResponse(srej: true), isCommand: false, pf: true)
        XCTAssertFalse(sent.contains { $0.displayInfo == "SABM" },
                       "a SABM went out for a connect that was given up")
    }

    func testXIDResponseEnablesSREJAndMinimumsThenSABM() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        let responses = manager.handleInboundXID(
            from: peer, path: DigiPath(), radio: .primary,
            info: xidResponse(srej: true, n1: 64, k: 2), isCommand: false, pf: true)
        XCTAssertTrue(responses.isEmpty, "an XID response draws no reply")

        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" }, "SABM follows the answer")
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertTrue(session.stateMachine.config.srejEnabled)
        XCTAssertEqual(session.stateMachine.config.windowSize, 2, "k = min(ours 4, theirs 2)")
        XCTAssertEqual(session.stateMachine.config.paclen, 64, "paclen = min(ours 128, their N1 64)")
    }

    func testPeerWithoutSREJGetsPlainGoBackN() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundXID(
            from: peer, path: DigiPath(), radio: .primary,
            info: xidResponse(srej: false), isCommand: false, pf: true)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertFalse(session.stateMachine.config.srejEnabled)
        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" })
    }

    /// §6.3.2: pre-2.2 implementations answer XID with FRMR. That is the
    /// documented "no" — connect proceeds with defaults, never fails.
    func testFRMRFallsBackToPlainSABM() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        manager.handleInboundFRMRDuringNegotiation(from: peer, radio: .primary)

        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" })
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
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
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        XCTAssertFalse(sent.contains { $0.displayInfo == "SABM" })

        XCTAssertTrue(manager.handleInboundDMDuringNegotiation(from: peer, radio: .primary),
                      "the DM belongs to the negotiation and is consumed by it")

        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" },
                      "the answer arrived; there is nothing left to wait for")
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertFalse(session.stateMachine.config.srejEnabled)
        XCTAssertEqual(session.state, .connecting)
    }

    /// The SABM the negotiation just sent must survive. A DM consumed here
    /// and *also* run through normal handling would reach a `.connecting`
    /// session as "connection refused" and cancel the connect it started.
    func testDMOutsideNegotiationIsNotConsumed() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundDMDuringNegotiation(from: peer, radio: .primary)

        XCTAssertFalse(manager.handleInboundDMDuringNegotiation(from: peer, radio: .primary),
                       "negotiation is over; a later DM is a real refusal")
    }

    /// Smoke run 2026-10-03-1, 12.4: A (705) sent XID to DRLNOD, heard
    /// nothing within T1, and sent SABM; DRLNOD's DM to the XID landed
    /// 0.45 s later, before the SABM had left the radio, and was taken as
    /// a refusal of it. DRLNOD's UA then found no session, and A answered
    /// DRLNOD's poll with DM. A frame that arrives before our SABM is out
    /// cannot answer it: it is the XID's late answer.
    func testALateDMToATimedOutXIDIsNotARefusalOfTheSABM() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        clock.advance(by: 2.01)  // just past the 2.0 s RTO: XID given up, SABM sent
        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" })
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connecting)
        XCTAssertGreaterThan(session.onAirUntil, clock.currentTime, "the SABM is still going out")

        // As the coordinator does: a frame heard is noted before it is handled.
        manager.noteFrameHeard(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertTrue(manager.handleInboundDMDuringNegotiation(from: peer, radio: .primary),
                      "the DM answers the XID, not the SABM")
        XCTAssertEqual(session.state, .connecting, "still waiting for the SABM's answer")
        XCTAssertTrue(manager.xidMemory.isKnownUnsupported(peer.display),
                      "the peer answered XID with DM: the next connect skips XID")

        _ = manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.state, .connected)
    }

    /// Once the SABM is on the air, a DM is its answer: a refusal.
    func testADMAfterTheSABMIsOutIsStillARefusal() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        clock.advance(by: 3.0)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        clock.currentTime = session.onAirUntil + 0.5

        manager.noteFrameHeard(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertFalse(manager.handleInboundDMDuringNegotiation(from: peer, radio: .primary))
        manager.handleInboundDM(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertNotEqual(session.state, .connecting, "the connect was refused")
    }

    /// The same for FRMR, the spec's own "no XID here" answer (§6.3.2).
    func testALateFRMRToATimedOutXIDIsNotARefusalOfTheSABM() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        clock.advance(by: 2.01)
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)

        manager.noteFrameHeard(from: peer, path: DigiPath(), radio: .primary)
        XCTAssertTrue(manager.handleInboundFRMRDuringNegotiation(from: peer, radio: .primary))
        XCTAssertEqual(session.state, .connecting)
    }

    func testSilentPeerTimesOutOnceAndIsCached() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        XCTAssertFalse(sent.contains { $0.displayInfo == "SABM" })

        clock.advance(by: 3.0)  // past the 2.0 s RTO
        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" },
                      "timeout falls back to the classic connect")

        // Tear down and reconnect: the peer is now known pre-2.2 — no XID.
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        manager.forceDisconnect(session: session)
        manager.removeSession(session)
        sent = []
        let frame = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(frame?.displayInfo, "SABM", "one RTO paid once, not per connect")
    }

    func testSecondConnectAfterSuccessfulXIDSkipsStraightToSABMWithSREJ() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundXID(
            from: peer, path: DigiPath(), radio: .primary,
            info: xidResponse(srej: true), isCommand: false, pf: true)
        let first = manager.session(for: peer, path: DigiPath(), radio: .primary)
        manager.forceDisconnect(session: first)
        manager.removeSession(first)
        sent = []

        let frame = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(frame?.displayInfo, "SABM", "capabilities are cached per callsign")
        let session = manager.session(for: peer, path: DigiPath(), radio: .primary)
        XCTAssertTrue(session.stateMachine.config.srejEnabled)
    }

    /// Field capture 2026-08-24, first on-air XID: the Winlink transport
    /// calls connect() and then awaits the outcome — but during the XID
    /// phase the session still reads `.disconnected`, which the awaiter
    /// took for "refused" milliseconds after the XID went out. The user
    /// saw "connect refused" followed by the link connecting anyway.
    /// While negotiation is pending, the outcome must stay undecided.
    func testAwaitOutcomeDoesNotReadPendingNegotiationAsRefused() async {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        let key = SessionKey(destination: peer, path: DigiPath(), radio: .primary)

        let outcomeTask = Task { [manager] in
            await manager!.awaitConnectionOutcome(key: key, timeout: 3.0)
        }
        // Give the awaiter time for its first poll — the one that used to
        // return .refused instantly.
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Peer answers XID (pre-2.2 peers would FRMR here instead — same
        // resolution path), SABM goes out, UA completes the link.
        _ = manager.handleInboundXID(
            from: peer, path: DigiPath(), radio: .primary,
            info: xidResponse(srej: true), isCommand: false, pf: true)
        manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)

        let outcome = await outcomeTask.value
        XCTAssertEqual(outcome, .connected,
                       "a pending XID is a connection in progress, not a refusal")
    }

    func testNegotiationDisabledConnectsClassically() {
        manager.negotiateV22 = false
        let frame = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(frame?.displayInfo, "SABM")
    }

    // MARK: - Inbound negotiation (we are the responder)

    func testInboundXIDCommandDrawsAResponseSelectingSREJ() {
        var offer = AX25XIDParameters()
        offer.supportsSREJ = true
        let responses = manager.handleInboundXID(
            from: peer, path: DigiPath(), radio: .primary,
            info: offer.encoded(isCommand: true), isCommand: true, pf: true)

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.displayInfo, "XID")
        XCTAssertEqual(responses.first?.controlByte, 0xBF, "response mirrors F=1")
        let parsed = AX25XIDParameters.parse(responses.first?.payload ?? Data())
        XCTAssertEqual(parsed?.supportsSREJ, true, "we accept the offered SREJ")

        // The SABM that follows creates a session that honors the agreement.
        _ = manager.handleInboundSABM(from: peer, to: manager.localCallsign, path: DigiPath(), radio: .primary)
        let session = manager.existingSession(for: peer)!
        XCTAssertTrue(session.stateMachine.config.srejEnabled)
    }

    func testInboundXIDOfferWithoutSREJIsAnsweredWithoutSREJ() {
        var offer = AX25XIDParameters()
        offer.supportsSREJ = false
        let responses = manager.handleInboundXID(
            from: peer, path: DigiPath(), radio: .primary,
            info: offer.encoded(isCommand: true), isCommand: true, pf: true)
        let parsed = AX25XIDParameters.parse(responses.first?.payload ?? Data())
        XCTAssertEqual(parsed?.supportsSREJ, false,
                       "never select an option the peer did not offer")

        _ = manager.handleInboundSABM(from: peer, to: manager.localCallsign, path: DigiPath(), radio: .primary)
        XCTAssertFalse(manager.existingSession(for: peer)!.stateMachine.config.srejEnabled)
    }

    func testMalformedXIDIsTreatedAsUnsupported() {
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundXID(
            from: peer, path: DigiPath(), radio: .primary,
            info: Data([0xDE, 0xAD]), isCommand: false, pf: true)
        XCTAssertTrue(sent.contains { $0.displayInfo == "SABM" },
                      "garbage in the answer still must not strand the connect")
        XCTAssertFalse(manager.session(for: peer, path: DigiPath(), radio: .primary)
            .stateMachine.config.srejEnabled)
    }

    // MARK: - Inbound SABME (modulo 128) is declined, not accepted

    // We are modulo 8 only, so an inbound SABME must be answered with DM (not
    // UA) to make the peer fall back to modulo 8. Accepting it stranded the peer
    // in an XID retry loop against a link this side cannot run.
    func testInboundSABMEIsRefusedWithDM() {
        let response = manager.handleInboundSABM(
            from: peer, to: manager.localCallsign, path: DigiPath(),
            radio: .primary, extended: true, pf: true)

        XCTAssertEqual(response?.displayInfo, "DM", "SABME (modulo 128) must be refused with DM")
        XCTAssertNil(manager.existingSession(for: peer),
                     "a refused SABME must not open a session")
    }

    // A plain SABM (modulo 8) is still accepted with UA.
    func testInboundSABMIsAcceptedWithUA() {
        let response = manager.handleInboundSABM(
            from: peer, to: manager.localCallsign, path: DigiPath(),
            radio: .primary, extended: false, pf: true)

        XCTAssertEqual(response?.displayInfo, "UA", "SABM (modulo 8) is accepted with UA")
        XCTAssertNotNil(manager.existingSession(for: peer),
                        "an accepted SABM opens a session")
    }
}
