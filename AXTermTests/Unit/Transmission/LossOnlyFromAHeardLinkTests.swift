//
//  LossOnlyFromAHeardLinkTests.swift
//  AXTermTests
//
//  Park rehearsal 2026-10-08, finding 35. For 20 minutes the phone could
//  send to A (705) but not hear it. Each time the phone called, A answered
//  and sent its banner, and each time A's T1 ran out it sent the banner
//  again and reported the resends to the link controller as loss. The phone
//  never had those links; it kept sending SABM. At 16:11:19Z the route to
//  K0EPI-3 fell to K 1 / P 64, and the next call, with the phone hearing
//  fine, downloaded at 19 B/s.
//
//  Smaller frames and a smaller window help a lossy channel. They do
//  nothing for a station that hears nothing. So resends count as loss only
//  once the peer is heard on the link: they are held until a frame from the
//  peer arrives, and dropped if the peer resets the link or the link ends
//  first.
//

import XCTest
@testable import AXTerm

@MainActor
final class LossOnlyFromAHeardLinkTests: XCTestCase {

    private let local = AX25Address(call: "K0EPI", ssid: 4)
    private let remote = AX25Address(call: "K0EPI", ssid: 3)

    private func called(_ manager: AX25SessionManager) throws -> AX25Session {
        _ = manager.handleInboundSABM(from: remote, to: local, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: remote, path: DigiPath(), radio: .primary))
        XCTAssertEqual(session.state, .connected)
        return session
    }

    func testATimeoutResendTeachesNothingUntilThePeerIsHeard() throws {
        let manager = AX25SessionManager(localCallsign: local)
        let session = try called(manager)
        var samples: [LinkQualitySample] = []
        manager.onLinkQualitySample = { _, sample in samples.append(sample) }

        _ = manager.sendData(Data("banner\r".utf8), to: remote, path: DigiPath(), radio: .primary)
        _ = manager.handleT1Timeout(session: session)
        XCTAssertTrue(samples.isEmpty, "nothing heard from the peer yet: no evidence either way")

        _ = manager.handleInboundRRFrames(from: remote, path: DigiPath(), radio: .primary,
                                          nr: 1, pf: false, isCommand: false)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.newFrames, 1)
        XCTAssertEqual(samples.first?.retransmits, 1, "the resend counts once the peer acknowledges")
    }

    /// The phone at 16:09Z: it kept calling, so each call reset a link it
    /// had never had. What A resent on the old link teaches nothing.
    func testAPeerResettingTheLinkDropsTheHeldResends() throws {
        let manager = AX25SessionManager(localCallsign: local)
        let session = try called(manager)
        var samples: [LinkQualitySample] = []
        manager.onLinkQualitySample = { _, sample in samples.append(sample) }

        _ = manager.sendData(Data("banner\r".utf8), to: remote, path: DigiPath(), radio: .primary)
        _ = manager.handleT1Timeout(session: session)
        _ = manager.handleT1Timeout(session: session)
        _ = manager.handleInboundSABM(from: remote, to: local, path: DigiPath(), radio: .primary)

        _ = manager.sendData(Data("banner\r".utf8), to: remote, path: DigiPath(), radio: .primary)
        _ = manager.handleInboundRRFrames(from: remote, path: DigiPath(), radio: .primary,
                                          nr: 1, pf: false, isCommand: false)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.retransmits, 0, "the resends on the link that was reset are gone")
    }

    func testALinkThatDiesWithNothingHeardTeachesNothing() throws {
        let manager = AX25SessionManager(localCallsign: local)
        let session = try called(manager)
        var samples: [LinkQualitySample] = []
        manager.onLinkQualitySample = { _, sample in samples.append(sample) }

        _ = manager.sendData(Data("banner\r".utf8), to: remote, path: DigiPath(), radio: .primary)
        for _ in 0...(session.stateMachine.config.maxRetries + 1) {
            _ = manager.handleT1Timeout(session: session)
            if session.state == .error { break }
        }
        XCTAssertEqual(session.state, .error, "precondition: N2 ran out")
        XCTAssertTrue(samples.isEmpty)
    }

    /// End to end, as on the air: the outage leaves the route as it was.
    func testTheOutageLeavesTheRouteAsItWas() throws {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.adaptiveTransmissionEnabled = true
        coordinator.sessionManager.localCallsign = local
        let before = coordinator.sessionManager.getConfigForDestination?("K0EPI-3", "", .primary)

        for _ in 0..<5 {
            _ = coordinator.sessionManager.handleInboundSABM(from: remote, to: local, path: DigiPath(),
                                                             radio: .primary)
            let session = try XCTUnwrap(coordinator.sessionManager.existingSession(
                for: remote, path: DigiPath(), radio: .primary))
            _ = coordinator.sessionManager.sendData(Data("banner\r".utf8), to: remote,
                                                    path: DigiPath(), radio: .primary)
            _ = coordinator.sessionManager.handleT1Timeout(session: session)
            _ = coordinator.sessionManager.handleT1Timeout(session: session)
        }

        let after = coordinator.sessionManager.getConfigForDestination?("K0EPI-3", "", .primary)
        XCTAssertEqual(after?.windowSize, before?.windowSize)
        XCTAssertEqual(after?.paclen, before?.paclen)
    }
}
