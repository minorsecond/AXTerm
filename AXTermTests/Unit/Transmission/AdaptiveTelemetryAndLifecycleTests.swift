//
//  AdaptiveTelemetryAndLifecycleTests.swift
//  AXTermTests
//
//  Audit follow-up (2026-08-22): the adaptive controller's evidence stream
//  and lifecycle must be complete, not just correct on the happy path.
//
//  1. Loss evidence comes from a link the peer is heard on. A T1 timeout
//     resend is held until a frame from the peer arrives (park rehearsal
//     2026-10-08, finding 35; this used to emit at once). A dying link that
//     never answers has said nothing about the channel.
//  2. Skepticism EARNED on a link (resends the peer then acknowledged)
//     survives that link's failure; resends nobody acknowledged do not
//     count (finding 35; the final unanswered resends used to be flushed).
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
        _ = manager.connect(to: destination, path: path, radio: .primary)
        let session = manager.session(for: destination, path: path, radio: .primary)
        manager.handleInboundUA(from: destination, path: path, radio: .primary)
        XCTAssertEqual(session.state, .connected)
        return session
    }

    // MARK: - Timely loss evidence

    /// A T1 timeout resend is held until the peer is heard, then counted.
    /// Until 2026-10-08 it was reported at once, and 20 minutes of a phone
    /// that could not hear A collapsed the route (finding 35).
    func testT1TimeoutRetransmissionIsCountedOnceThePeerIsHeard() {
        let manager = AX25SessionManager(localCallsign: local)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: remote, path: path)

        var samples: [LinkQualitySample] = []
        manager.onLinkQualitySample = { _, sample in samples.append(sample) }

        _ = manager.sendData(Data("mh 3\r".utf8), to: remote, path: path, radio: .primary)
        XCTAssertEqual(session.outstandingCount, 1)

        let frames = manager.handleT1Timeout(session: session)
        XCTAssertFalse(frames.filter { $0.frameType == "i" }.isEmpty,
                       "precondition: T1 timeout retransmitted the frame")
        XCTAssertTrue(samples.isEmpty, "held until the peer is heard")

        _ = manager.handleInboundRRFrames(from: remote, path: path, radio: .primary,
                                          nr: 1, pf: false, isCommand: false)
        XCTAssertEqual(samples.count, 1)
        XCTAssertGreaterThanOrEqual(samples.first?.retransmits ?? 0, 1)
        XCTAssertGreaterThan(samples.first?.lossRate ?? 0, 0)
    }

    /// N2 exhaustion with nothing heard from the peer reports nothing: a
    /// station that hears nothing is not helped by smaller frames
    /// (finding 35). This used to flush the final resends as loss.
    func testLinkFailureWithNothingHeardReportsNoLoss() {
        let manager = AX25SessionManager(localCallsign: local)
        let path = DigiPath()
        let session = connectSession(manager: manager, destination: remote, path: path)

        var samples: [LinkQualitySample] = []
        manager.onLinkQualitySample = { _, sample in samples.append(sample) }

        _ = manager.sendData(Data("b\r".utf8), to: remote, path: path, radio: .primary)
        let maxRetries = session.stateMachine.config.maxRetries
        for _ in 0...(maxRetries + 1) {
            _ = manager.handleT1Timeout(session: session)
            if session.state == .error { break }
        }
        XCTAssertEqual(session.state, .error, "precondition: N2 exhausted the link")
        XCTAssertTrue(samples.isEmpty, "unanswered resends are not channel loss")
    }

    /// RNR acks were wired into the sampler alongside I-frame/REJ; pin it.
    func testRNRAckEmitsLinkQualitySample() {
        let manager = AX25SessionManager(localCallsign: local)
        let path = DigiPath()
        _ = connectSession(manager: manager, destination: remote, path: path)

        var samples: [LinkQualitySample] = []
        manager.onLinkQualitySample = { _, sample in samples.append(sample) }

        _ = manager.sendData(Data("A".utf8), to: remote, path: path, radio: .primary)
        _ = manager.handleInboundRNR(from: remote, path: path, radio: .primary,
                                     nr: 1, pf: false, isCommand: false)
        XCTAssertEqual(samples.count, 1, "an RNR's N(R) is an acknowledgment like any other")
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

        _ = manager.sendData(Data("A".utf8), to: remote, path: path, radio: .primary)
        // Corrupt the watermark past the real counter, then create genuine
        // retransmit evidence so the sampler has something to report.
        session.lastSampledFramesSent = session.statistics.framesSent + 5
        session.statistics.recordRetransmit()

        _ = manager.handleInboundRRFrames(from: remote, path: path, radio: .primary,
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

        let key = AdaptiveScope.route(radio: .primary, destination: "KB5YZB-7", path: path.display)
        coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: 5.0,
                                           source: "session", scope: key,
                                           newFrames: 1, retransmits: 0)

        // The peer disconnects normally — the REAL teardown path, so this
        // also pins that a lingering ended session cannot force the merged
        // config (which never carries learned state) onto the reconnect.
        _ = coordinator.sessionManager.handleInboundDISC(from: remote, path: path, radio: .primary)
        XCTAssertEqual(session.state, .disconnected, "precondition: real teardown ran")

        let config = coordinator.sessionManager.getConfigForDestination?("KB5YZB-7", path.display, .primary)
        XCTAssertEqual(config?.learnedPathRto ?? -1, 10.0, accuracy: 0.01,
                       "the learned full-path RTO must survive disconnect and seed the reconnect")
    }

    /// Skepticism EARNED on a link survives its failure: resends the peer
    /// acknowledged collapse the route, and the reconnect starts there.
    /// Resends nobody acknowledged no longer earn it (finding 35).
    func testEarnedSkepticismSurvivesLinkFailure() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.adaptiveTransmissionEnabled = true

        let path = DigiPath.from(["DRLNOD"])
        let session = connectSession(manager: coordinator.sessionManager,
                                     destination: remote, path: path)

        // A lossy channel first: frames that needed resending before the
        // peer acknowledged them, a live loss sample each time (via the
        // coordinator's own wiring).
        for i in 0..<3 {
            _ = coordinator.sessionManager.sendData(Data("a\(i)\r".utf8), to: remote,
                                                    path: path, radio: .primary)
            _ = coordinator.sessionManager.handleT1Timeout(session: session)
            _ = coordinator.sessionManager.handleInboundRRFrames(
                from: remote, path: path, radio: .primary, nr: (i + 1) % 8, pf: false, isCommand: false)
        }
        // Then the link dies: unanswered T1 retransmissions exhaust N2.
        _ = coordinator.sessionManager.sendData(Data("b\r".utf8), to: remote,
                                                path: path, radio: .primary)
        let maxRetries = session.stateMachine.config.maxRetries
        for _ in 0...(maxRetries + 1) {
            _ = coordinator.sessionManager.handleT1Timeout(session: session)
            if session.state == .error { break }
        }
        XCTAssertEqual(session.state, .error, "precondition: N2 exhausted the link")

        let config = coordinator.sessionManager.getConfigForDestination?("KB5YZB-7", path.display, .primary)
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

        _ = manager.sendData(Data("b\r".utf8), to: remote, path: path, radio: .primary)
        let maxRetries = dead.stateMachine.config.maxRetries
        for _ in 0...(maxRetries + 1) {
            _ = manager.handleT1Timeout(session: dead)
            if dead.state == .error { break }
        }
        XCTAssertEqual(dead.state, .error, "precondition: N2 exhausted the link")

        let sabm = manager.connect(to: remote, path: path, radio: .primary)
        XCTAssertNotNil(sabm, "reconnect after failure must be possible")

        let fresh = manager.session(for: remote, path: path, radio: .primary)
        XCTAssertNotIdentical(fresh, dead, "the reconnect gets a fresh session, not the carcass")
        XCTAssertEqual(fresh.state, .connecting)
        XCTAssertEqual(fresh.timers.rto, 3.0, accuracy: 0.01,
                       "fresh timers seed from config (3 s, spec 7.3), not the dead session's")
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

        let key = AdaptiveScope.route(radio: .primary, destination: "KB5YZB-7", path: path.display)
        coordinator.applyLinkQualitySample(lossRate: 0.0, etx: 1.0, srtt: 5.0,
                                           source: "session", scope: key,
                                           newFrames: 1, retransmits: 0)

        _ = coordinator.sessionManager.handleInboundDISC(from: remote, path: path, radio: .primary)

        let sabm = coordinator.sessionManager.connect(to: remote, path: path, radio: .primary)
        XCTAssertNotNil(sabm)
        let fresh = coordinator.sessionManager.session(for: remote, path: path, radio: .primary)
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

        _ = manager.sendData(Data("b\r".utf8), to: remote, path: path, radio: .primary)
        let maxRetries = dead.stateMachine.config.maxRetries
        for _ in 0...(maxRetries + 1) {
            _ = manager.handleT1Timeout(session: dead)
            if dead.state == .error { break }
        }
        XCTAssertEqual(dead.state, .error)

        let ua = manager.handleInboundSABM(from: remote, to: local, path: path, radio: .primary)
        XCTAssertNotNil(ua, "the peer's fresh SABM deserves a UA, not silence")

        let fresh = manager.session(for: remote, path: path, radio: .primary)
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
            _ = manager.sendData(Data("chunk-\(i)\r".utf8), to: remote, path: path, radio: .primary)
        }
        for _ in 0...(config.maxRetries + 1) {
            _ = manager.handleT1Timeout(session: dead)
            if dead.state == .error { break }
        }
        XCTAssertEqual(dead.state, .error)
        XCTAssertTrue(dead.pendingDataQueue.isEmpty,
                      "teardown clears the queue DELIBERATELY (logged reason), not by discard")

        _ = manager.connect(to: remote, path: path, radio: .primary)
        let fresh = manager.session(for: remote, path: path, radio: .primary)
        XCTAssertNotIdentical(fresh, dead)
        XCTAssertEqual(fresh.pendingDataQueue.count, dead.pendingDataQueue.count,
                       "the discard transfers whatever the carcass held — zero here, but never less")
    }

    /// Data sent to a peer whose last link has ended goes out on the new
    /// link. sendData picked the ended session, then connect() replaced it
    /// with a fresh one, and the data was queued on the session just thrown
    /// away. Smoke run 2026-10-03-1, 7.2: after two Winlink calls to
    /// K0EPI-3, a NET/ROM circuit's CONREQ was lost this way; the link came
    /// up and A never sent it.
    func testDataSentAfterTheLastLinkEndedGoesOutOnTheNewLink() {
        let manager = AX25SessionManager(localCallsign: local)
        let path = DigiPath()
        let ended = connectSession(manager: manager, destination: remote, path: path)
        _ = manager.handleInboundDISC(from: remote, path: path, radio: .primary)
        XCTAssertEqual(ended.state, .disconnected, "precondition: the peer ended the first link")

        let payload = Data("conreq".utf8)
        _ = manager.sendData(payload, to: remote, path: path, radio: .primary)

        let fresh = manager.session(for: remote, path: path, radio: .primary)
        XCTAssertNotIdentical(fresh, ended)
        XCTAssertEqual(fresh.pendingDataQueue.map(\.data), [payload],
                       "the data waits on the session that is connecting")

        manager.handleInboundUA(from: remote, path: path, radio: .primary)
        XCTAssertEqual(fresh.state, .connected)
        XCTAssertTrue(fresh.pendingDataQueue.isEmpty)
        XCTAssertEqual(fresh.outstandingCount, 1, "the data went out as the new link's first I-frame")
    }

    // MARK: - Link-failure escalation (keeps Sentry quiet for normal RF life)

    /// A single link failure is normal packet-radio life (out of range, node
    /// rebooted) and must stay a breadcrumb. Only RAPID REPETITION — the
    /// pattern that smells like a defect — escalates to a Sentry event, and
    /// escalating resets the counter so a sustained bad evening produces a
    /// trickle, not a barrage.
    func testLinkFailureEscalatesOnlyOnRapidRepetition() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        let t0 = Date()

        XCTAssertFalse(coordinator.noteLinkFailureForEscalation(at: t0),
                       "one failure: normal radio life, no event")
        XCTAssertFalse(coordinator.noteLinkFailureForEscalation(at: t0.addingTimeInterval(60)),
                       "two failures: still no event")
        XCTAssertTrue(coordinator.noteLinkFailureForEscalation(at: t0.addingTimeInterval(120)),
                      "third failure inside the window: this pattern is worth one event")
        XCTAssertFalse(coordinator.noteLinkFailureForEscalation(at: t0.addingTimeInterval(180)),
                       "escalation resets the counter — no immediate repeat")
    }

    func testLinkFailureEscalationWindowForgetsOldFailures() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        let t0 = Date()

        XCTAssertFalse(coordinator.noteLinkFailureForEscalation(at: t0))
        XCTAssertFalse(coordinator.noteLinkFailureForEscalation(at: t0.addingTimeInterval(5 * 60)))
        // The third failure arrives after the first has aged out of the
        // 10-minute window: two-in-window is not a storm.
        XCTAssertFalse(coordinator.noteLinkFailureForEscalation(at: t0.addingTimeInterval(11 * 60)),
                       "failures spread over a long session never escalate")
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
