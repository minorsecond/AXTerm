//
//  AXDPCapabilityProbeTests.swift
//  AXTermTests
//
//  The AXDP capability check asks again when nothing comes back.
//
//  On 2026-09-30, over a lossy 1200 baud link between two AXTerm stations,
//  K0EPI-3's PONG was lost on the air. The probe and the PONG both travel as
//  UI frames, which nothing below AXDP retransmits, and the prober never asked
//  again. K0EPI-2's Send File sheet said "Checking..." for the 15 minutes the
//  check waited, offering only YAPP. See Docs/LiveRFTest-2026-09-30.md, bug 1.
//
//  The timer passes here are driven with an explicit `now`, the same way the
//  transfer watchdog is tested, so nothing waits on a real clock.
//

import XCTest
@testable import AXTerm

// MARK: - Schedule

final class AXDPCapabilityProbeScheduleTests: XCTestCase {

    func testIntervalHasAFloorOfSeveralSeconds() {
        XCTAssertEqual(AXDPCapabilityProbe.interval(rto: nil), AXDPCapabilityProbe.minimumInterval)
        XCTAssertEqual(AXDPCapabilityProbe.interval(rto: 1.0), AXDPCapabilityProbe.minimumInterval)
        XCTAssertEqual(AXDPCapabilityProbe.interval(rto: .nan), AXDPCapabilityProbe.minimumInterval)
        XCTAssertGreaterThanOrEqual(AXDPCapabilityProbe.minimumInterval, 5)
    }

    func testIntervalFollowsASlowLinksRTO() {
        let rto = AXDPCapabilityProbe.minimumInterval + 7
        XCTAssertEqual(AXDPCapabilityProbe.interval(rto: rto), rto)
    }

    func testIntervalIsCapped() {
        XCTAssertEqual(AXDPCapabilityProbe.interval(rto: 600), AXDPCapabilityProbe.maximumInterval)
    }

    func testAsksThreeTimesThenGivesUp() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var probe = AXDPCapabilityProbe(sentAt: start, rto: nil)
        let interval = probe.interval
        XCTAssertEqual(AXDPCapabilityProbe.maxAttempts, 3)
        XCTAssertEqual(probe.attempts, 1)

        XCTAssertEqual(probe.step(at: start.addingTimeInterval(interval - 0.1)), .wait)
        XCTAssertEqual(probe.step(at: start.addingTimeInterval(interval)), .resend)
        probe.noteResent(at: start.addingTimeInterval(interval))
        XCTAssertEqual(probe.attempts, 2)

        XCTAssertEqual(probe.step(at: start.addingTimeInterval(2 * interval - 0.1)), .wait)
        XCTAssertEqual(probe.step(at: start.addingTimeInterval(2 * interval)), .resend)
        probe.noteResent(at: start.addingTimeInterval(2 * interval))
        XCTAssertEqual(probe.attempts, 3)

        XCTAssertEqual(probe.step(at: start.addingTimeInterval(3 * interval - 0.1)), .wait)
        XCTAssertEqual(probe.step(at: start.addingTimeInterval(3 * interval)), .giveUp)
    }

    func testAProbeLeftPastTheWholeScheduleGivesUp() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let probe = AXDPCapabilityProbe(sentAt: start, rto: nil)
        let total = AXDPCapabilityProbe.totalWait(rto: nil)
        XCTAssertEqual(probe.giveUpAt, start.addingTimeInterval(total))
        XCTAssertEqual(probe.step(at: start.addingTimeInterval(total - 0.1)), .resend)
        XCTAssertEqual(probe.step(at: start.addingTimeInterval(total)), .giveUp)
    }

    /// The whole check is over in well under the old 15 minutes, even on the
    /// slowest link the interval allows.
    func testTheLongestCheckIsBoundedByTheRetrySchedule() {
        let longest = AXDPCapabilityProbe.totalWait(rto: 600)
        XCTAssertEqual(longest, AXDPCapabilityProbe.maximumInterval * Double(AXDPCapabilityProbe.maxAttempts))
        XCTAssertLessThanOrEqual(longest, 120)
    }
}

// MARK: - Coordinator

@MainActor
final class AXDPCapabilityProbeRetryTests: XCTestCase {

    private var coordinator: SessionCoordinator!
    private var sends: [CapabilityDebugEvent] = []
    private let local = AX25Address(call: "K0EPI", ssid: 2)
    private let peer = AX25Address(call: "K0EPI", ssid: 3)

    override func setUp() {
        super.setUp()
        coordinator = SessionCoordinator()
        coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
        coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
        coordinator.sessionManager.localCallsign = local
        sends = []
        coordinator.onCapabilityEvent = { [weak self] event in
            if event.type == .pingSent { self?.sends.append(event) }
        }
    }

    override func tearDown() {
        coordinator = nil
        SessionCoordinator.shared = nil
        super.tearDown()
    }

    /// We called the peer, it sent us something, and we sent the text probe.
    @discardableResult
    private func connectAsInitiatorAndProbe() -> AX25Session {
        let session = coordinator.sessionManager.session(for: peer)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)
        coordinator.sessionManager.onSessionStateChanged?(session, .connecting, .connected)
        coordinator.sessionManager.onDataDeliveredForReassembly?(session, "Hello\r".data(using: .ascii)!)
        return session
    }

    private func pong() -> AXDP.Message {
        AXDP.Message(type: .pong, sessionId: 0, messageId: 1, capabilities: AXDPCapability.defaultLocal())
    }

    func testALostPongIsAskedAgainOnTheRetrySchedule() {
        let start = Date()
        let session = connectAsInitiatorAndProbe()
        let interval = AXDPCapabilityProbe.interval(rto: session.timers.rto)
        XCTAssertEqual(sends.count, 1, "the first probe")

        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(interval / 2))
        XCTAssertEqual(sends.count, 1, "nothing is resent before the interval is up")

        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(interval + 0.5))
        XCTAssertEqual(sends.count, 2, "no PONG: ask again")
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display, now: start.addingTimeInterval(interval + 1)),
                       .pending)

        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(2 * interval + 1))
        XCTAssertEqual(sends.count, 3, "and once more")
    }

    func testAfterTheLastAttemptTheCheckGivesUpAsNoAnswer() {
        let start = Date()
        let session = connectAsInitiatorAndProbe()
        let interval = AXDPCapabilityProbe.interval(rto: session.timers.rto)

        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(interval + 0.5))
        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(2 * interval + 1))
        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(3 * interval + 2))

        XCTAssertEqual(sends.count, 3, "three attempts and no more")
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .notSupported)
        XCTAssertFalse(coordinator.isCapabilityDiscoveryPending(for: peer.display))
        XCTAssertEqual(coordinator.availableProtocols(for: peer.display), [.yapp],
                       "YAPP is still offered")

        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(10 * interval))
        XCTAssertEqual(sends.count, 3, "nothing more after giving up")
    }

    /// The status the sheet shows stops saying pending once the schedule has
    /// run out, even if no timer pass has run yet. It used to hold for 15 minutes.
    func testStatusStopsBeingPendingWhenTheScheduleRunsOut() {
        let start = Date()
        let session = connectAsInitiatorAndProbe()
        let bound = AXDPCapabilityProbe.totalWait(rto: session.timers.rto)

        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display, now: start.addingTimeInterval(1)), .pending)
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display, now: start.addingTimeInterval(bound + 1)),
                       .notSupported)
    }

    func testAPongStopsFurtherAttempts() {
        let start = Date()
        let session = connectAsInitiatorAndProbe()
        let interval = AXDPCapabilityProbe.interval(rto: session.timers.rto)

        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(interval + 0.5))
        XCTAssertEqual(sends.count, 2)

        coordinator.handleCapabilityMessage(pong(), from: peer, path: DigiPath())
        let afterPong = sends.count   // includes our own PING, the other half of the exchange

        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(2 * interval + 1))
        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(3 * interval + 2))
        XCTAssertEqual(sends.count, afterPong, "a PONG ends the retries")
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .confirmed)
    }

    /// Any AXDP message from the peer proves it speaks AXDP; there is nothing
    /// left to ask.
    func testAnyAXDPMessageFromThePeerStopsFurtherAttempts() {
        let start = Date()
        let session = connectAsInitiatorAndProbe()
        let interval = AXDPCapabilityProbe.interval(rto: session.timers.rto)

        let chat = AXDP.Message(type: .chat, sessionId: 9, messageId: 9, payload: Data("hi".utf8))
        coordinator.testHandleAXDPMessage(chat, from: peer)

        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(interval + 0.5))
        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(3 * interval + 2))
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .confirmed)
    }

    func testAPongAfterGivingUpStillConfirmsAXDP() {
        let start = Date()
        let session = connectAsInitiatorAndProbe()
        let interval = AXDPCapabilityProbe.interval(rto: session.timers.rto)
        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(interval + 0.5))
        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(2 * interval + 1))
        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(3 * interval + 2))
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .notSupported)

        coordinator.handleCapabilityMessage(pong(), from: peer, path: DigiPath())

        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .confirmed)
        XCTAssertEqual(coordinator.availableProtocols(for: peer.display).first, .axdp)
    }

    func testDisconnectEndsTheRetries() {
        let start = Date()
        let session = connectAsInitiatorAndProbe()
        let interval = AXDPCapabilityProbe.interval(rto: session.timers.rto)

        coordinator.sessionManager.onSessionStateChanged?(session, .connected, .disconnected)
        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(interval + 0.5))
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .unknown)
    }

    /// A binary PING sent inside the session travels in I-frames, which the link
    /// layer retransmits, but its PONG always comes back as a UI frame. That PONG
    /// can be lost too, so this check is retried the same way.
    func testASessionPingIsRetriedToo() {
        let start = Date()
        let session = coordinator.sessionManager.session(for: peer)
        _ = session.stateMachine.handle(event: .connectRequest)
        _ = session.stateMachine.handle(event: .receivedUA)
        let interval = AXDPCapabilityProbe.interval(rto: session.timers.rto)

        coordinator.sendCapabilityPing(to: session)
        XCTAssertEqual(sends.count, 1)
        coordinator.runCapabilityProbeTimers(now: start.addingTimeInterval(interval + 0.5))
        XCTAssertEqual(sends.count, 2)
    }

    // MARK: Opening the Send File sheet

    /// The station that answered the call never probes on its own, so its sheet
    /// sat on "Unknown". Opening the sheet starts the check.
    func testOpeningTheSheetStartsACheckForAPeerNobodyAsked() {
        _ = coordinator.sessionManager.handleInboundSABM(from: peer, to: local, path: DigiPath(),
                                                         radio: .primary)
        XCTAssertNotNil(coordinator.sessionManager.connectedSession(withPeer: peer))
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .unknown)

        coordinator.requestCapabilityCheck(for: peer.display)

        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .pending)
    }

    func testOpeningTheSheetAgainDoesNotSendAnotherProbe() {
        connectAsInitiatorAndProbe()
        coordinator.requestCapabilityCheck(for: peer.display)
        XCTAssertEqual(sends.count, 1, "a check is already running")
    }

    func testOpeningTheSheetDoesNotProbeWhenAutoNegotiateIsOff() {
        coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = false
        _ = coordinator.sessionManager.handleInboundSABM(from: peer, to: local, path: DigiPath(),
                                                         radio: .primary)
        coordinator.requestCapabilityCheck(for: peer.display)
        XCTAssertEqual(sends.count, 0)
        XCTAssertEqual(coordinator.capabilityStatus(for: peer.display), .unknown)
    }

    func testOpeningTheSheetDoesNotProbeAStationWeAreNotConnectedTo() {
        coordinator.requestCapabilityCheck(for: peer.display)
        XCTAssertEqual(sends.count, 0)
    }
}

// MARK: - Send File sheet badge

@MainActor
final class SendFileCapabilityBadgeTextTests: XCTestCase {

    func testPendingSaysChecking() {
        let text = SendFileCapabilityBadgeText(status: .pending, callsign: "K0EPI-3")
        XCTAssertEqual(text.label, "Checking\u{2026}")
    }

    func testNoAnswerSaysSoPlainlyAndPointsToYAPP() {
        let text = SendFileCapabilityBadgeText(status: .notSupported, callsign: "K0EPI-3")
        XCTAssertEqual(text.label, "No answer")
        XCTAssertTrue(text.help.contains("K0EPI-3 did not answer the AXDP check"), text.help)
        XCTAssertTrue(text.help.contains("YAPP"), text.help)
    }

    func testConfirmedSaysAXDP() {
        XCTAssertEqual(SendFileCapabilityBadgeText(status: .confirmed, callsign: "K0EPI-3").label, "AXDP")
    }

    func testUnknownSaysUnknown() {
        XCTAssertEqual(SendFileCapabilityBadgeText(status: .unknown, callsign: "K0EPI-3").label, "Unknown")
    }
}
