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
