//
//  NetRomRelayLifecycleTests.swift
//  AXTermTests
//
//  Setting NET/ROM mode and connecting to KB5YZB-7 left the operator sitting at
//  DRLNOD's "ENTER COMMAND:" prompt (2026-08-26). The relay machinery was whole —
//  it arms, waits for the node banner, sends `C KB5YZB-7`, and reads the answer —
//  but it was disarmed a moment after arming, by the appearance of its own
//  session.
//
//  A session is born `.disconnected` and stays there until its SABM goes out.
//  With XID negotiation ahead of the SABM that window is seconds long — eight of
//  them against DRLNOD, which answers XID with DM. The teardown rule watched the
//  level rather than the transition, so "this link has not come up yet" and "this
//  link went away" were the same signal.
//

import XCTest
@testable import AXTerm

final class NetRomRelayLifecycleTests: XCTestCase {

    /// The bug: a session appearing in its initial state is not a link failure.
    func testSessionAppearingDoesNotAbandonTheRelay() {
        XCTAssertFalse(NetRomRelayLifecycle.abandonsRelay(onDisconnectFrom: nil),
                       "no prior state means the session has only just appeared")
    }

    /// Nor is a redundant republish of that same initial state.
    func testStayingDisconnectedDoesNotAbandonTheRelay() {
        XCTAssertFalse(NetRomRelayLifecycle.abandonsRelay(onDisconnectFrom: .disconnected))
    }

    /// A connect that was refused — DM from the peer, or the N2 ladder running
    /// out — is a dead relay and must be abandoned.
    func testFailedConnectAbandonsTheRelay() {
        XCTAssertTrue(NetRomRelayLifecycle.abandonsRelay(onDisconnectFrom: .connecting))
    }

    /// So is a link that was carrying the relay and dropped.
    func testLostLinkAbandonsTheRelay() {
        XCTAssertTrue(NetRomRelayLifecycle.abandonsRelay(onDisconnectFrom: .connected))
    }

    /// And an operator-initiated teardown.
    func testDeliberateDisconnectAbandonsTheRelay() {
        XCTAssertTrue(NetRomRelayLifecycle.abandonsRelay(onDisconnectFrom: .disconnecting))
    }

    // MARK: - Reading the node's answer

    /// The exact bytes DRLNOD sent back after `C KB5YZB-7` (2026-08-26).
    /// Recognising this is what completes the handshake; without it the relay
    /// waits forever, one step from done.
    func testBPQLinkMadeIsSuccess() {
        XCTAssertTrue(NetRomRelayResponseParser.isSuccess("###LINK MADE\r"))
        XCTAssertFalse(NetRomRelayResponseParser.isFailure("###LINK MADE\r"))
    }

    /// The wordings that already worked keep working.
    func testOtherNodeWordingsStillSucceed() {
        for reply in ["*** CONNECTED TO KB5YZB-7", "Connected to KB5YZB-7",
                      "LINKED TO KB5YZB-7", "Link established"] {
            XCTAssertTrue(NetRomRelayResponseParser.isSuccess(reply), reply)
        }
    }

    /// A teardown notice must never read as a successful connect. This is why
    /// the success list has no bare "connected" — "disconnected" contains it.
    func testDisconnectIsNotReadAsSuccess() {
        XCTAssertFalse(NetRomRelayResponseParser.isSuccess("*** DISCONNECTED"))
        XCTAssertFalse(NetRomRelayResponseParser.isSuccess("Disconnected from node"))
    }

    /// BPQ's refusals are recognised as refusals, not left to time out.
    func testNodeRefusalsAreFailures() {
        for reply in ["Failure with KB5YZB-7", "No route to KB5YZB-7",
                      "Downlink denied", "Invalid command", "Busy from KB5YZB-7"] {
            XCTAssertTrue(NetRomRelayResponseParser.isFailure(reply), reply)
            XCTAssertFalse(NetRomRelayResponseParser.isSuccess(reply), reply)
        }
    }

    /// A KA-Node whose own connect attempt exhausted retries says so
    /// plainly (field capture 2026-08-28 18:40). Unrecognised, the relay
    /// sat through the answer for another 40 s of watchdog grace.
    func testRetriedOutIsAFailure() {
        let reply = "###RETRIED OUT AT NODE DRLNOD"
        XCTAssertTrue(NetRomRelayResponseParser.isFailure(reply))
        XCTAssertFalse(NetRomRelayResponseParser.isSuccess(reply))
    }

    /// The node's own welcome banner is neither — it arrives before the connect
    /// command is even sent, and reading it either way would decide the
    /// handshake on the wrong frame.
    func testNodeBannerIsNeitherVerdict() {
        let banner = "ENTER COMMAND: B,C,J,N, or Help ?"
        XCTAssertFalse(NetRomRelayResponseParser.isSuccess(banner))
        XCTAssertFalse(NetRomRelayResponseParser.isFailure(banner))
    }

    // MARK: - Where the bytes actually go

    /// The second half of the same defect (2026-08-26). The relay handshake
    /// completed — `C KB5YZB-1` went out through DRLNOD, the node answered
    /// `###LINK MADE`, and KB5YZB's BBS banner came back — and then the first
    /// thing typed left as a fresh SABM addressed to KB5YZB-1 direct, opening a
    /// second link that had nothing to do with the circuit.
    func testEstablishedRelaySendsToTheNextHop() {
        let wire = NetRomRelayLifecycle.wireDestination(
            typed: ("KB5YZB-1", ""), establishedNextHop: "DRLNOD")
        XCTAssertEqual(wire.call, "DRLNOD",
                       "the circuit rides the link to the node; the node forwards")
    }

    /// A digipeater path belongs to the destination the operator typed. The
    /// node is reached directly, and what happens past it is the node's affair.
    func testEstablishedRelayDropsTheTypedPath() {
        let wire = NetRomRelayLifecycle.wireDestination(
            typed: ("KB5YZB-1", "WIDE1-1"), establishedNextHop: "DRLNOD")
        XCTAssertEqual(wire.call, "DRLNOD")
        XCTAssertEqual(wire.path, "")
    }

    /// The 17:53 capture: the relay was armed and waiting on DRLNOD's banner,
    /// the operator typed `nodes`, and the redirect — gated on `.established` —
    /// let it out as a fresh direct SABM to KB5YZB-7. A relay in *any* live
    /// phase must own the destination.
    func testHandshakingRelayAlsoOwnsTheDestination() {
        let wire = NetRomRelayLifecycle.wireDestination(
            typed: ("KB5YZB-7", ""), establishedNextHop: "DRLNOD")
        XCTAssertEqual(wire.call, "DRLNOD",
                       "no direct link to the destination while a circuit is in flight")
    }

    /// With no relay, nothing is redirected — an ordinary connect is untouched,
    /// digipeaters and all.
    func testOrdinaryConnectIsUntouched() {
        let wire = NetRomRelayLifecycle.wireDestination(
            typed: ("KB5YZB-1", "DRLNOD"), establishedNextHop: nil)
        XCTAssertEqual(wire.call, "KB5YZB-1")
        XCTAssertEqual(wire.path, "DRLNOD")
    }

    /// A next hop that is present but empty is not a relay — treat it as none
    /// rather than addressing frames to nowhere.
    func testEmptyNextHopIsNotARelay() {
        let wire = NetRomRelayLifecycle.wireDestination(
            typed: ("KB5YZB-1", ""), establishedNextHop: "")
        XCTAssertEqual(wire.call, "KB5YZB-1")
    }

    // MARK: - Progress tracking follows the acks

    /// The composer read "Sending…" forever while KB5YZB-7's reply was already
    /// on screen (2026-08-26): the progress was keyed to the destination, and
    /// every acknowledgement came from DRLNOD.
    func testAckPeerIsTheCarrierNotTheDestination() {
        let prog = OutboundMessageProgress(
            id: UUID(), text: "nodes", totalBytes: 6, bytesSent: 0, bytesAcked: 0,
            destination: "KB5YZB-7",
            ackPeer: "DRLNOD", timestamp: Date(),
            hasAcks: true, startingVs: 0, totalChunks: 1, paclen: 128,
            lastKnownVa: 0, chunksAcked: 0)

        XCTAssertEqual(prog.destination, "KB5YZB-7",
                       "the operator is told who they are talking to")
        XCTAssertEqual(prog.ackPeer, "DRLNOD",
                       "and progress follows whoever actually acknowledges")
    }

    /// With no relay the two are the same station, so nothing about an ordinary
    /// send changes.
    func testOrdinarySendHasOneIdentity() {
        let prog = OutboundMessageProgress(
            id: UUID(), text: "hi", totalBytes: 3, bytesSent: 0, bytesAcked: 0,
            destination: "KB5YZB-1",
            ackPeer: "KB5YZB-1", timestamp: Date(),
            hasAcks: true, startingVs: 0, totalChunks: 1, paclen: 128,
            lastKnownVa: 0, chunksAcked: 0)
        XCTAssertEqual(prog.destination, prog.ackPeer)
    }

    func testErroredLinkAbandonsTheRelay() {
        XCTAssertTrue(NetRomRelayLifecycle.abandonsRelay(onDisconnectFrom: .error))
    }

    /// Every state the link can actually reach ends the relay; only the two
    /// forms of "not yet" spare it. Stated exhaustively so a new case in
    /// `AX25SessionState` has to be considered here rather than defaulting.
    func testOnlyNotYetSparesTheRelay() {
        for state in [AX25SessionState.connecting, .connected, .disconnecting, .error] {
            XCTAssertTrue(NetRomRelayLifecycle.abandonsRelay(onDisconnectFrom: state),
                          "\(state.rawValue) is a link that existed")
        }
    }

    // MARK: - Which station the operator is told they are talking to

    /// The bug: the connect bar is pointed at the next hop to raise the L2
    /// link and never pointed back, so the header kept saying DRLNOD while the
    /// conversation was with KB5YZB-7 (reported 2026-08-27).
    func testEstablishedRelayIsNamedByItsFarEnd() {
        XCTAssertEqual(
            NetRomRelayLifecycle.displayedDestination(
                typed: "DRLNOD", establishedDestination: "KB5YZB-7"),
            "KB5YZB-7")
    }

    /// No relay, no rewriting: an ordinary link is named by what was dialled.
    func testDirectLinkKeepsTheTypedDestination() {
        XCTAssertEqual(
            NetRomRelayLifecycle.displayedDestination(
                typed: "K0NTS-10", establishedDestination: nil),
            "K0NTS-10")
    }

    /// Mid-handshake there is no far end yet. The wire redirect arms here; the
    /// display must not, or the header claims a connection the node has not
    /// agreed to.
    func testHandshakeStillShowsTheNodeBeingDialled() {
        // A relay in flight supplies no established destination.
        XCTAssertEqual(
            NetRomRelayLifecycle.displayedDestination(
                typed: "DRLNOD", establishedDestination: nil),
            "DRLNOD")
        // ...while the wire is already redirected at the same moment.
        let wire = NetRomRelayLifecycle.wireDestination(
            typed: (call: "KB5YZB-7", path: ""), establishedNextHop: "DRLNOD")
        XCTAssertEqual(wire.call, "DRLNOD",
                       "the two rules diverge on purpose during the handshake")
    }

    /// An empty destination is not an answer; fall back rather than blank the
    /// header.
    func testEmptyRelayDestinationFallsBack() {
        XCTAssertEqual(
            NetRomRelayLifecycle.displayedDestination(
                typed: "DRLNOD", establishedDestination: ""),
            "DRLNOD")
    }

    // MARK: - Telling REJ recovery from silence

    /// The 2026-08-28 capture: the chain had reached COSCO, DRLNOD's frames 4
    /// and 5 swapped on air, and frame 5 was being retransmitted while the
    /// watchdog counted delivered-text silence. It flushed the gap 240 ms
    /// before the resend of frame 4 — the "Connected to COSCO" confirmation —
    /// arrived, and a connection that had succeeded on air was torn down.
    /// I-frames still arriving means recovery is running: wait.
    func testArrivingIFramesDeferTheStallVerdict() {
        XCTAssertEqual(
            NetRomRelayLifecycle.stallVerdict(
                tickMoved: false, inboundIFramesMoved: true,
                deferralSpent: 0, deferralBudget: 60),
            .peerStillTransmitting)
    }

    /// The 2026-08-27 deadlock that motivated the flush: a peer that answers
    /// every poll but never resends the missing frame produces no I-frames at
    /// all. That is real silence and must still stall on schedule.
    func testPollAnswersWithoutIFramesStillStall() {
        XCTAssertEqual(
            NetRomRelayLifecycle.stallVerdict(
                tickMoved: false, inboundIFramesMoved: false,
                deferralSpent: 0, deferralBudget: 60),
            .stalled)
    }

    /// A peer resending the wrong frame forever must not hold the relay open:
    /// once the deferral budget is spent, arriving I-frames stop counting.
    func testTheDeferralIsBudgeted() {
        XCTAssertEqual(
            NetRomRelayLifecycle.stallVerdict(
                tickMoved: false, inboundIFramesMoved: true,
                deferralSpent: 60, deferralBudget: 60),
            .stalled)
    }

    /// Delivered text is the strongest signal and resets everything — a chain
    /// that is walking normally is never touched.
    func testDeliveredTextOutranksEverything() {
        XCTAssertEqual(
            NetRomRelayLifecycle.stallVerdict(
                tickMoved: true, inboundIFramesMoved: true,
                deferralSpent: 999, deferralBudget: 60),
            .chainAdvanced)
    }

    /// The counter the watchdog samples: every connected-mode I-frame counts,
    /// deliverable or not — an out-of-sequence retransmission that only gets
    /// buffered is exactly the arrival the deferral exists to notice.
    func testUndeliverableIFramesStillMoveTheCounter() {
        var sm = AX25StateMachine(config: AX25SessionConfig())
        _ = sm.handle(event: .connectRequest)
        _ = sm.handle(event: .receivedUA)
        XCTAssertEqual(sm.inboundIFrameCount, 0)

        // ns=1 with vr=0: out of sequence, buffered behind the gap, nothing
        // delivered — the shape of the DRLNOD capture.
        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false,
                                             payload: Data("late".utf8)))
        XCTAssertEqual(sm.inboundIFrameCount, 1)

        // The retransmission of the same frame counts again: it is proof the
        // peer is transmitting now, which is all the watchdog asks.
        _ = sm.handle(event: .receivedIFrame(ns: 1, nr: 0, pf: false,
                                             payload: Data("late".utf8)))
        XCTAssertEqual(sm.inboundIFrameCount, 2)

        // An RR is a poll answer, not recovery traffic — it must not count,
        // or the 2026-08-27 poll-forever deadlock never stalls.
        _ = sm.handle(event: .receivedRR(nr: 0, pf: true, isCommand: true))
        XCTAssertEqual(sm.inboundIFrameCount, 2)
    }

    // MARK: - Arming on a link that is already up

    /// Field capture 2026-08-31. A NET/ROM circuit attempt to BBSCBH opened
    /// an AX.25 link to DRLNOD; DRLNOD greeted at 07:36:57 with its banner
    /// and `ENTER COMMAND:`. The circuit failed, the fallback prompt relay
    /// armed at 07:38:29 — and waited for a greeting that had already been
    /// and gone, on a link that produced no new `.connected` transition to
    /// start the banner watchdog. Nothing was ever sent; the session idled
    /// out at 07:39:21 having exchanged only RR polls.
    func testArmingOnALiveLinkMustNotSimplyWait() {
        XCTAssertEqual(
            NetRomRelayLifecycle.armingAction(linkAlreadyUp: true, bannerAlreadySeen: true),
            .promptNow,
            "the node greets once per connection; waiting is waiting forever")
    }

    /// The ordinary path: the link is about to be dialled, so the banner is
    /// still to come and `.connected` will start the watchdog.
    func testArmingBeforeTheLinkExistsWaitsForTheBanner() {
        XCTAssertEqual(
            NetRomRelayLifecycle.armingAction(linkAlreadyUp: false, bannerAlreadySeen: false),
            .awaitBanner)
    }

    /// Live link, but nothing has greeted on it yet — a CR would arrive
    /// while the node is still composing its banner. Watch, do not prod.
    func testALiveLinkThatHasNotGreetedYetIsOnlyWatched() {
        XCTAssertEqual(
            NetRomRelayLifecycle.armingAction(linkAlreadyUp: true, bannerAlreadySeen: false),
            .watchOnly)
    }

    /// A banner seen on some earlier link says nothing about one not yet
    /// dialled; the new connection will greet on its own.
    func testASpentBannerOnNoLinkStillWaits() {
        XCTAssertEqual(
            NetRomRelayLifecycle.armingAction(linkAlreadyUp: false, bannerAlreadySeen: true),
            .awaitBanner)
    }

    // MARK: - Remembering that a prompt went past

    /// The signal behind `bannerAlreadySeen`.
    func testTheDetectorRemembersANodePrompt() {
        var detector = ManualRelayDetector()
        XCTAssertFalse(detector.hasSeenNodePrompt)

        detector.processIncoming("ENTER COMMAND: B,C,J,N, or Help ?")
        XCTAssertTrue(detector.hasSeenNodePrompt)
    }

    /// A disconnect notice ends a relay but is not a prompt. Recording it
    /// as one would claim the greeting is spent on a link where the node
    /// has said nothing.
    func testADisconnectNoticeIsNotAPrompt() {
        var detector = ManualRelayDetector()
        detector.processIncoming("###DISCONNECTED FROM KB5YZB-7")
        XCTAssertFalse(detector.hasSeenNodePrompt)
    }

    /// The next connection greets afresh, so the memory cannot outlive the
    /// link — otherwise the first relay on a new link would prod a node
    /// that was about to greet anyway.
    func testTheMemoryIsClearedWithTheLink() {
        var detector = ManualRelayDetector()
        detector.processIncoming("ENTER COMMAND: B,C,J,N, or Help ?")
        detector.clear()
        XCTAssertFalse(detector.hasSeenNodePrompt)
    }

    /// BPQ words it differently.
    func testBPQsPromptCountsToo() {
        var detector = ManualRelayDetector()
        detector.processIncoming("Enter cmd: B,C,J,N,Q?")
        XCTAssertTrue(detector.hasSeenNodePrompt)
    }
}
