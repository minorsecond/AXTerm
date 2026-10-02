//
//  InboundConnectAnnouncementTests.swift
//  AXTermTests
//
//  Answering a caller comes before telling the operator about them.
//
//  Field case 2026-10-02 (live test log, bug 44): B sent its UA at
//  19:46:56.163 and its Winlink banner at 19:47:56.482, and its exchange
//  started 13 ms before the banner. The main thread was blocked for the
//  whole minute before the answering service ran, while a macOS microphone
//  prompt waited for the operator. On an inbound connect the coordinator
//  played the connection sound and posted the notification before it told
//  the services that answer calls. Bug 35's 8.8 s first greeting after a
//  relaunch came from the same spot.
//

import XCTest
@testable import AXTerm

@MainActor
final class InboundConnectAnnouncementTests: XCTestCase {

    private let local = AX25Address(call: "K0EPI", ssid: 3)
    private let peer = AX25Address(call: "K0EPI", ssid: 2)

    func testServicesHearOfTheCallBeforeTheOperatorIsTold() {
        let coordinator = SessionCoordinator()
        defer { SessionCoordinator.shared = nil }
        coordinator.localCallsign = "K0EPI-3"
        var order: [String] = []
        coordinator.announceConnection = { callsign, inbound in
            order.append("announce \(callsign) inbound=\(inbound)")
        }
        coordinator.addInboundSessionSubscriber { _ in order.append("subscriber") }
        coordinator.onInboundSessionConnected = { _ in order.append("listener") }

        coordinator.handleIncomingPacket(Packet(from: peer, to: local, via: [], frameType: .u, control: 0x3F))

        XCTAssertEqual(order, ["listener", "subscriber", "announce K0EPI-2 inbound=true"])
    }

    /// The chime can't hold up the app: a cold audio start, or a permission
    /// prompt the audio system raises, would otherwise block the main thread.
    func testTheConnectionSoundPlaysOffTheCallersThread() {
        let played = expectation(description: "played")
        var onMain: Bool?
        SessionCoordinator.playConnectionSound(inbound: true) { inbound in
            XCTAssertTrue(inbound)
            onMain = Thread.isMainThread
            played.fulfill()
        }
        wait(for: [played], timeout: 2)
        XCTAssertEqual(onMain, false)
    }

    /// A step on the inbound-connect path that takes over a second is named
    /// in the log, so the next stall says what it was.
    func testASlowStepIsReportedByName() {
        var times = [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 102.5)]
        var reported: [(String, TimeInterval)] = []
        SessionCoordinator.timedInboundStep("connection notification",
                                            now: { times.removeFirst() },
                                            report: { reported.append(($0, $1)) }) {}
        XCTAssertEqual(reported.map(\.0), ["connection notification"])
        XCTAssertEqual(reported.first?.1 ?? 0, 2.5, accuracy: 0.001)
    }

    func testAQuickStepIsNotReported() {
        var times = [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 100.2)]
        var reported = 0
        SessionCoordinator.timedInboundStep("subscriber",
                                            now: { times.removeFirst() },
                                            report: { _, _ in reported += 1 }) {}
        XCTAssertEqual(reported, 0)
    }
}
