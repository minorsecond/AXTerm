//
//  PollCheckpointHoldTests.swift
//  AXTermTests
//
//  No new I-frames while our poll is waiting for its final.
//
//  On 2026-10-01, with the window grown to K3, station A sent three 174-byte
//  frames with P=1 on the last. B's T2 fired part-way through that four
//  second burst, so B's TNC sent an RR acknowledging only the first two
//  frames, F=0, as soon as the channel cleared, and then B answered the
//  poll with RR F=1. A read the first RR as room in the window and keyed
//  up at once, straight over B's F=1. The losses walked the session back
//  down to K1 and paclen 64. AX.25 2.2's timer recovery already holds new
//  I-frames until the F=1 arrives; the same holds for a checkpoint poll.
//

import XCTest
@testable import AXTerm

@MainActor
final class PollCheckpointHoldTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 3)
    private let local = AX25Address(call: "K0EPI", ssid: 2)

    private final class SentLog { var frames: [OutboundFrame] = [] }

    private func connected() throws -> (AX25SessionManager, AX25Session, SentLog) {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: local, clock: clock)
        let log = SentLog()
        manager.onSendFrame = { log.frames.append($0) }
        _ = manager.handleInboundSABM(from: peer, to: local, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(manager.existingSession(for: peer, path: DigiPath(), radio: .primary))
        XCTAssertEqual(session.state, .connected)
        return (manager, session, log)
    }

    private func iFrames(_ frames: [OutboundFrame]) -> [OutboundFrame] {
        frames.filter { ($0.controlByte ?? 0x03) & 0x01 == 0 }
    }

    /// Sends a window-filling burst and returns how many frames it held.
    private func fillWindow(_ manager: AX25SessionManager, _ session: AX25Session, _ log: SentLog) -> Int {
        let window = session.liveWindowSize
        for i in 0..<window {
            log.frames += manager.sendData(Data("chunk \(i)".utf8), to: peer)
        }
        XCTAssertEqual(iFrames(log.frames).count, window, "precondition: the window filled")
        XCTAssertTrue(((iFrames(log.frames).last?.controlByte ?? 0) & 0x10) != 0,
                      "precondition: the frame that filled the window polls")
        return window
    }

    func testAPartialAckDoesNotReleaseNewFramesWhileThePollIsOutstanding() throws {
        let (manager, session, log) = try connected()
        let window = fillWindow(manager, session, log)
        log.frames.removeAll()

        // B's T2 ack for all but the last frame, F=0, before its F=1 answer.
        log.frames += manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                                    nr: window - 1, pf: false, isCommand: false)
        log.frames += manager.sendData(Data("next".utf8), to: peer)

        XCTAssertTrue(iFrames(log.frames).isEmpty,
                      "a new I-frame went out while the peer still owed the answer to our poll")
    }

    func testTheFinalReleasesTheHeldFrames() throws {
        let (manager, session, log) = try connected()
        let window = fillWindow(manager, session, log)
        log.frames += manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                                    nr: window - 1, pf: false, isCommand: false)
        log.frames += manager.sendData(Data("next".utf8), to: peer)
        log.frames.removeAll()

        log.frames += manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                                    nr: window, pf: true, isCommand: false)

        XCTAssertEqual(iFrames(log.frames).count, 1, "the held frame goes out once the final arrives")
    }

    func testAnAckForEverythingAlsoReleasesThem() throws {
        // A peer that acknowledges the whole burst without setting F still
        // gets the data; the hold must not wait on an F that never comes.
        let (manager, session, log) = try connected()
        let window = fillWindow(manager, session, log)
        log.frames += manager.handleInboundRRFrames(from: peer, path: DigiPath(), radio: .primary,
                                                    nr: window, pf: false, isCommand: false)
        log.frames.removeAll()

        log.frames += manager.sendData(Data("next".utf8), to: peer)

        XCTAssertEqual(iFrames(log.frames).count, 1)
    }

    func testWithNoPollOutstandingFramesFlowAsBefore() throws {
        let (manager, _, log) = try connected()
        log.frames += manager.sendData(Data("one".utf8), to: peer)

        XCTAssertEqual(iFrames(log.frames).count, 1)
    }
}
