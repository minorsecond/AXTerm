//
//  AdaptiveTelemetryAndLifecycleTests.swift
//  AXTermTests
//
//  Audit follow-up (2026-08-22): the adaptive controller's evidence stream
//  and lifecycle must be complete, not just correct on the happy path.
//
//  1. Loss evidence must be TIMELY — a T1 timeout retransmission is loss the
//     controller should hear immediately, not when the next inbound frame
//     happens to arrive (a dying link never sends one).
//  2. Loss evidence must survive LINK FAILURE — the final retransmissions of
//     a dying session are exactly the evidence that should make the next
//     attempt skeptical.
//  3. Learned state must survive DISCONNECT — the 30-minute TTL is the
//     staleness authority, not session teardown. Evicting on disconnect
//     silently defeated learned-RTO seeding for every reconnect.
//  4. The sampler must be defensive about its own invariants (monotonic
//     statistics counters) rather than trusting them implicitly.
//

import XCTest
@testable import AXTerm

@MainActor
final class AdaptiveTelemetryAndLifecycleTests: XCTestCase {

    private let local = AX25Address(call: "K0EPI", ssid: 7)
    private let remote = AX25Address(call: "KB5YZB", ssid: 7)

    private func connectSession(
        manager: AX25SessionManager,
        destination: AX25Address,
        path: DigiPath
    ) -> AX25Session {
        _ = manager.connect(to: destination, path: path, channel: 0)
        let session = manager.session(for: destination, path: path, channel: 0)
        manager.handleInboundUA(from: destination, path: path, channel: 0)
        XCTAssertEqual(session.state, .connected)
        return session
    }

    // MARK: - Timely loss evidence

    /// A T1 timeout retransmission is loss evidence NOW. Waiting for the next
    /// inbound frame to carry the delta means a degrading link — the one case
    /// where inbound frames stop coming — reports its loss last or never.
    func testT1TimeoutRetransmissionEmitsLossSampleImmediately() {
        let manager = AX25SessionManager(localCallsign: local)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: remote, path: path)

        var samples: [LinkQualitySample] = []
        manager.onLinkQualitySample = { _, sample in samples.append(sample) }

        _ = manager.sendData(Data("mh 3\r".utf8), to: remote, path: path, channel: 0)
        XCTAssertEqual(session.outstandingCount, 1)

        let frames = manager.handleT1Timeout(session: session)
        XCTAssertFalse(frames.filter { $0.frameType == "i" }.isEmpty,
                       "precondition: T1 timeout retransmitted the frame")
        XCTAssertEqual(samples.count, 1,
                       "the retransmission must reach the controller without waiting for inbound traffic")
        XCTAssertGreaterThanOrEqual(samples.first?.retransmits ?? 0, 1)
        XCTAssertGreaterThan(samples.first?.lossRate ?? 0, 0)
    }

    /// N2 exhaustion tears the link down — and the retransmissions on the way
    /// down are exactly the evidence that should make the NEXT attempt on this
    /// route skeptical. The final sample must flush even in the error state.
    func testLinkFailureFlushesFinalLossEvidence() {
        let manager = AX25SessionManager(localCallsign: local)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: remote, path: path)

        var samples: [LinkQualitySample] = []
        manager.onLinkQualitySample = { _, sample in samples.append(sample) }

        _ = manager.sendData(Data("b\r".utf8), to: remote, path: path, channel: 0)
        let maxRetries = session.stateMachine.config.maxRetries
        for _ in 0...(maxRetries + 1) {
            _ = manager.handleT1Timeout(session: session)
            if session.state == .error { break }
        }
        XCTAssertEqual(session.state, .error, "precondition: N2 exhausted the link")
        XCTAssertFalse(samples.isEmpty, "the dying link's loss evidence must not vanish with it")
        XCTAssertTrue(samples.allSatisfy { $0.retransmits >= 1 || $0.newFrames >= 1 },
                      "every sample carries real evidence")
        XCTAssertGreaterThanOrEqual(samples.last?.retransmits ?? 0, 1,
                                    "the final flush carries the terminal retransmissions")
    }

    /// RNR acks were wired into the sampler alongside I-frame/REJ; pin it.
    func testRNRAckEmitsLinkQualitySample() {
        let manager = AX25SessionManager(localCallsign: local)
        let path = DigiPath()
        _ = connectSession(manager: manager, destination: remote, path: path)

        var samples: [LinkQualitySample] = []
        manager.onLinkQualitySample = { _, sample in samples.append(sample) }

        _ = manager.sendData(Data("A".utf8), to: remote, path: path, channel: 0)
        _ = manager.handleInboundRNR(from: remote, path: path, channel: 0,
                                     nr: 1, pf: false, isCommand: false)
        XCTAssertEqual(samples.count, 1, "an RNR's N(R) is an acknowledgement like any other")
        XCTAssertEqual(samples.first?.newFrames, 1)
    }

    // MARK: - Sampler defends its own invariants

    /// The delta watermarks assume monotonic statistics. If that ever breaks,
    /// the sampler must clamp rather than hand the controller negative
    /// evidence or a loss rate above 1.
    func testSamplerClampsNonMonotonicStatisticsDeltas() {
        let manager = AX25SessionManager(localCallsign: local)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: remote, path: path)

        var samples: [LinkQualitySample] = []
        manager.onLinkQualitySample = { _, sample in samples.append(sample) }

        _ = manager.sendData(Data("A".utf8), to: remote, path: path, channel: 0)
        // Corrupt the watermark past the real counter, then create genuine
        // retransmit evidence so the sampler has something to report.
        session.lastSampledFramesSent = session.statistics.framesSent + 5
        session.statistics.recordRetransmit()

        _ = manager.handleInboundRRFrames(from: remote, path: path, channel: 0,
                                          nr: 1, pf: false, isCommand: false)

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.newFrames, 0,
                       "a negative sent-delta clamps to zero — never negative evidence")
        XCTAssertLessThanOrEqual(samples.first?.lossRate ?? 2.0, 1.0)
        XCTAssertGreaterThanOrEqual(samples.first?.retransmits ?? 0, 1)
    }

    // MARK: - Learned state survives the session lifecycle

    /// Learn on a route, disconnect, reconnect: the learned RTO must still
    /// seed the connect timer. The 30-minute TTL is the staleness authority —
    /// eviction-on-disconnect silently defeated the feature in the field.
    func testLearnedStateSurvivesDisconnectUntilTTL() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.adaptiveTransmissionEnabled = true

        let path = DigiPath.from(["DRLNOD"])
        let session = connectSession(manager: coordinator.sessionManager,
                                     destination: remote, path: path)

        let key = RouteAdaptiveKey(destination: "KB5YZB-7", pathSignature: path.display)
        coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: 5.0,
                                           source: "session", routeKey: key,
                                           newFrames: 1, retransmits: 0)

        // The peer disconnects normally — the REAL teardown path, so this
        // also pins that a lingering ended session cannot force the merged
        // config (which never carries learned state) onto the reconnect.
        _ = coordinator.sessionManager.handleInboundDISC(from: remote, path: path, channel: 0)
        XCTAssertEqual(session.state, .disconnected, "precondition: real teardown ran")

        let config = coordinator.sessionManager.getConfigForDestination?("KB5YZB-7", path.display)
        XCTAssertEqual(config?.learnedPathRto ?? -1, 10.0, accuracy: 0.01,
                       "the learned full-path RTO must survive disconnect and seed the reconnect")
    }

    /// A route that FAILED must stay remembered as skeptical: the collapsed
    /// K/paclen carry into the next attempt instead of resetting to optimism.
    func testEarnedSkepticismSurvivesLinkFailure() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.adaptiveTransmissionEnabled = true

        let path = DigiPath.from(["DRLNOD"])
        let session = connectSession(manager: coordinator.sessionManager,
                                     destination: remote, path: path)

        // The link dies for real: unanswered T1 retransmissions exhaust N2.
        // Each retransmission is a live loss sample into the per-route cache
        // (via the coordinator's own wiring), so the collapse to skepticism
        // is driven end-to-end by genuine evidence, not injected samples.
        _ = coordinator.sessionManager.sendData(Data("b\r".utf8), to: remote,
                                                path: path, channel: 0)
        let maxRetries = session.stateMachine.config.maxRetries
        for _ in 0...(maxRetries + 1) {
            _ = coordinator.sessionManager.handleT1Timeout(session: session)
            if session.state == .error { break }
        }
        XCTAssertEqual(session.state, .error, "precondition: N2 exhausted the link")

        let config = coordinator.sessionManager.getConfigForDestination?("KB5YZB-7", path.display)
        XCTAssertEqual(config?.windowSize, 1,
                       "stop-and-wait skepticism carries into the reconnect")
        XCTAssertEqual(config?.paclen, 64,
                       "small-frame skepticism carries into the reconnect")
    }

    // MARK: - Reconnect must not run through a dead session's carcass

    /// connect() through a lingering .error session reused the object — with
    /// the OLD config baked in at creation and timers still holding the
    /// backed-off RTO the link died with (rtoMax). The retry — the moment the
    /// operator most wants responsiveness — inherited maximum sluggishness.
    /// A dead session must be replaced by a fresh one on reconnect.
    func testReconnectAfterLinkFailureGetsFreshSessionAndTimers() {
        let manager = AX25SessionManager(localCallsign: local)
        let path = DigiPath()
        let dead = connectSession(manager: manager, destination: remote, path: path)

        _ = manager.sendData(Data("b\r".utf8), to: remote, path: path, channel: 0)
        let maxRetries = dead.stateMachine.config.maxRetries
        for _ in 0...(maxRetries + 1) {
            _ = manager.handleT1Timeout(session: dead)
            if dead.state == .error { break }
        }
        XCTAssertEqual(dead.state, .error, "precondition: N2 exhausted the link")
        XCTAssertGreaterThan(dead.timers.rto, 4.0, "precondition: the dead session's RTO backed off")

        let sabm = manager.connect(to: remote, path: path, channel: 0)
        XCTAssertNotNil(sabm, "reconnect after failure must be possible")

        let fresh = manager.session(for: remote, path: path, channel: 0)
        XCTAssertNotIdentical(fresh, dead, "the reconnect gets a fresh session, not the carcass")
        XCTAssertEqual(fresh.state, .connecting)
        XCTAssertEqual(fresh.timers.rto, 4.0, accuracy: 0.01,
                       "fresh timers seed from config, not the dead session's backed-off RTO")
        XCTAssertEqual(fresh.statistics.framesSent, 0, "fresh evidence counters")
    }

    /// The full field chain the learned-RTO feature promises: learn on a
    /// route, session ends, reconnect — the new session's connect timer runs
    /// at the learned full-path RTO. This exercises retention (no eviction),
    /// live-session counting (no merged config), and fresh-session creation
    /// (no carcass reuse) end to end.
    func testReconnectSeedsLearnedRtoEndToEnd() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.adaptiveTransmissionEnabled = true

        let path = DigiPath.from(["DRLNOD"])
        _ = connectSession(manager: coordinator.sessionManager, destination: remote, path: path)

        let key = RouteAdaptiveKey(destination: "KB5YZB-7", pathSignature: path.display)
        coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: 5.0,
                                           source: "session", routeKey: key,
                                           newFrames: 1, retransmits: 0)

        _ = coordinator.sessionManager.handleInboundDISC(from: remote, path: path, channel: 0)

        let sabm = coordinator.sessionManager.connect(to: remote, path: path, channel: 0)
        XCTAssertNotNil(sabm)
        let fresh = coordinator.sessionManager.session(for: remote, path: path, channel: 0)
        XCTAssertEqual(fresh.state, .connecting)
        XCTAssertEqual(fresh.timers.rto, 10.0, accuracy: 0.01,
                       "the reconnect's SABM runs at the learned full-path RTO (2 x srtt 5s), not the 12s hop-scaled default")
    }

    /// A peer re-SABMing into our lingering dead session must likewise get a
    /// fresh session — the (.error, .receivedSABM) pair has no state-machine
    /// transition at all, so the old object was a dead end.
    func testInboundSABMReplacesDeadSession() {
        let manager = AX25SessionManager(localCallsign: local)
        let path = DigiPath()
        let dead = connectSession(manager: manager, destination: remote, path: path)

        _ = manager.sendData(Data("b\r".utf8), to: remote, path: path, channel: 0)
        let maxRetries = dead.stateMachine.config.maxRetries
        for _ in 0...(maxRetries + 1) {
            _ = manager.handleT1Timeout(session: dead)
            if dead.state == .error { break }
        }
        XCTAssertEqual(dead.state, .error)

        let ua = manager.handleInboundSABM(from: remote, to: local, path: path, channel: 0)
        XCTAssertNotNil(ua, "the peer's fresh SABM deserves a UA, not silence")

        let fresh = manager.session(for: remote, path: path, channel: 0)
        XCTAssertNotIdentical(fresh, dead)
        XCTAssertEqual(fresh.state, .connected)
        XCTAssertFalse(fresh.isInitiator, "the peer initiated this one")
    }

    /// No data path through session replacement may drop bytes SILENTLY.
    /// Every teardown path clears the pending queue deliberately, each with
    /// its own logged reason ("Session error", "remote DISC", …) — so the
    /// carcass a reconnect discards must already be empty, and whatever it
    /// might hold (a future teardown path that forgets to clear) transfers to
    /// the fresh session rather than vanishing.
    func testReconnectNeverSilentlyDropsPendingData() {
        let manager = AX25SessionManager(localCallsign: local)
        let path = DigiPath()
        let dead = connectSession(manager: manager, destination: remote, path: path)

        // One frame in flight, one queued behind the window when the link dies.
        let config = dead.stateMachine.config
        for i in 0..<(config.windowSize + 1) {
            _ = manager.sendData(Data("chunk-\(i)\r".utf8), to: remote, path: path, channel: 0)
        }
        for _ in 0...(config.maxRetries + 1) {
            _ = manager.handleT1Timeout(session: dead)
            if dead.state == .error { break }
        }
        XCTAssertEqual(dead.state, .error)
        XCTAssertTrue(dead.pendingDataQueue.isEmpty,
                      "teardown clears the queue DELIBERATELY (logged reason), not by discard")

        _ = manager.connect(to: remote, path: path, channel: 0)
        let fresh = manager.session(for: remote, path: path, channel: 0)
        XCTAssertNotIdentical(fresh, dead)
        XCTAssertEqual(fresh.pendingDataQueue.count, dead.pendingDataQueue.count,
                       "the discard transfers whatever the carcass held — zero here, but never less")
    }

    // MARK: - Collapse detection (drives the warning breadcrumb)

    func testCollapseToStopAndWaitDetectsTheTransitionEdgeOnly() {
        XCTAssertTrue(SessionCoordinator.didCollapseToStopAndWait(beforeK: 4, afterK: 1))
        XCTAssertTrue(SessionCoordinator.didCollapseToStopAndWait(beforeK: 2, afterK: 1))
        XCTAssertFalse(SessionCoordinator.didCollapseToStopAndWait(beforeK: 1, afterK: 1),
                       "already collapsed — no repeat warning spam")
        XCTAssertFalse(SessionCoordinator.didCollapseToStopAndWait(beforeK: 4, afterK: 2),
                       "a halving that stops above 1 is a downgrade, not a collapse")
    }
}
