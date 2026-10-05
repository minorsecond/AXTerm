//
//  IdlePollSettingTests.swift
//  AXTermTests
//
//  T3, the idle poll, is the operator's to set: 300 s by default.
//
//  AX.25 2.2 §6.7.1.3: "The period of T3 is locally defined, and depends
//  greatly on Layer 1 operation. T3 should be greater than T1; it may be
//  very large on channels of high integrity." Linux, Direwolf and the
//  Kenwood D710A use 300 s. AXTerm used 30 s, and in smoke run 2026-10-03-1
//  (test 12.4) it polled DRLNOD and W0ARP-7 about every 27 s on a shared
//  channel. Operator decision 2026-10-05: adjustable, default 300 s, never
//  below T1, the spread between stations kept.
//

import XCTest
@testable import AXTerm

@MainActor
final class IdlePollSettingTests: XCTestCase {

    private let peer = AX25Address(call: "DRLNOD", ssid: 0)
    private let local = AX25Address(call: "K0EPI", ssid: 2)

    private func idleSession(_ manager: AX25SessionManager) -> AX25Session {
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        return manager.session(for: peer, path: DigiPath(), radio: .primary)
    }

    /// The first poll on an idle link, in seconds after it went idle.
    private func firstPoll(_ manager: AX25SessionManager, _ clock: AX25VirtualClock) -> Double? {
        var polls: [Double] = []
        manager.onSendFrame = { frame in if frame.frameType == "s" { polls.append(clock.currentTime) } }
        let start = clock.currentTime
        for _ in 0..<4000 {
            clock.advance(by: 1)
            if let first = polls.first { return first - start }
        }
        return nil
    }

    // MARK: - The setting

    func testTheDefaultIsThreeHundredSeconds() {
        let settings = AppSettingsStore(defaults: TestDefaults.make("IdlePollDefault"))
        XCTAssertEqual(settings.ax25T3IdleSeconds, 300)
        XCTAssertEqual(AppSettingsStore.defaultAX25T3IdleSeconds, 300)
    }

    func testTheSettingIsKeptInRangeAndSaved() {
        let defaults = TestDefaults.make("IdlePollRange")
        let settings = AppSettingsStore(defaults: defaults)
        settings.ax25T3IdleSeconds = 5
        XCTAssertEqual(settings.ax25T3IdleSeconds, AppSettingsStore.minAX25T3IdleSeconds)
        settings.ax25T3IdleSeconds = 99_999
        XCTAssertEqual(settings.ax25T3IdleSeconds, AppSettingsStore.maxAX25T3IdleSeconds)
        settings.ax25T3IdleSeconds = .nan
        XCTAssertEqual(settings.ax25T3IdleSeconds, AppSettingsStore.defaultAX25T3IdleSeconds)
        settings.ax25T3IdleSeconds = 600
        XCTAssertEqual(AppSettingsStore(defaults: defaults).ax25T3IdleSeconds, 600, "kept across a relaunch")
    }

    // MARK: - The session layer

    func testAnIdleLinkFirstPollsAtTheSettingNotThirtySeconds() throws {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.t3JitterDraw = { 0 }   // the full period
        _ = idleSession(manager)
        let first = try XCTUnwrap(firstPoll(manager, clock))
        XCTAssertEqual(first, 300, accuracy: 1)
    }

    func testTheOperatorsValueIsUsed() throws {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.t3JitterDraw = { 1 }   // the shortest draw: three quarters
        manager.idleT3Seconds = { 120 }
        _ = idleSession(manager)
        let first = try XCTUnwrap(firstPoll(manager, clock))
        XCTAssertEqual(first, 90, accuracy: 1)
    }

    /// §6.7.1.3: T3 should be greater than T1.
    func testAPeriodIsNeverShorterThanT1() throws {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        manager.defaultConfig = AX25SessionConfig(initialRto: 3.0, learnedPathRto: 50)
        manager.t3JitterDraw = { 1 }
        manager.idleT3Seconds = { 30 }   // drawn as 22.5 s, under T1V's 50 s
        let session = idleSession(manager)
        XCTAssertEqual(session.timers.rto, 50, accuracy: 1e-9)
        let first = try XCTUnwrap(firstPoll(manager, clock))
        XCTAssertGreaterThanOrEqual(first, 50)
    }

    func testTheCoordinatorFollowsTheSetting() throws {
        let settings = AppSettingsStore(defaults: TestDefaults.make("IdlePollCoordinator"))
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.appSettings = settings
        settings.ax25T3IdleSeconds = 450
        XCTAssertEqual(coordinator.sessionManager.idleT3Seconds(), 450)
    }
}
