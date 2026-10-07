//
//  AckWhenChannelClearsTests.swift
//  AXTermTests
//
//  T2 holds an ack in case more frames of the peer's transmission follow
//  (AX.25 2.2 §6.7.1.2). It must outlast a full frame's airtime, about 2 s
//  at 1200 bit/s, so every lone typed line waited 2 s for its RR. A radio
//  whose modem is ours hears the carrier end: once the channel is clear,
//  nothing more of that transmission is coming, and the ack goes out then
//  (smoke run 2026-10-07, 13.4, issue 113). A TNC that reports no carrier
//  keeps the full T2.
//

import XCTest
@testable import AXTerm

@MainActor
final class AckWhenChannelClearsTests: XCTestCase {
    private let me = AX25Address(call: "K0EPI", ssid: 2)
    private let peer = AX25Address(call: "K0EPI", ssid: 3)
    private let modemRadio = RadioID(rawValue: "sound-modem")
    private let otherRadio = RadioID(rawValue: "tnc4")

    private func linkWithAFrameOwedAnAck(clock: AX25VirtualClock) -> (AX25SessionManager, [OutboundFrame]) {
        let manager = AX25SessionManager(localCallsign: me, clock: clock)
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }
        _ = manager.handleInboundSABM(from: peer, to: me, path: DigiPath(), radio: modemRadio)
        let immediate = manager.handleInboundIFrame(from: peer, to: me, path: DigiPath(), radio: modemRadio,
                                                    ns: 0, nr: 0, pf: false, payload: Data("Test\r".utf8))
        XCTAssertNil(immediate, "a frame without P waits for T2")
        return (manager, sent)
    }

    func testTheAckGoesOutWhenTheChannelClears() {
        let clock = AX25VirtualClock()
        let (manager, _) = linkWithAFrameOwedAnAck(clock: clock)
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }

        clock.advance(by: 0.3)
        manager.channelCleared(on: modemRadio)

        XCTAssertEqual(sent.filter { $0.frameType == "s" }.count, 1, "RR 1 goes out with the channel clear")
        clock.advance(by: 3)
        XCTAssertEqual(sent.filter { $0.frameType == "s" }.count, 1, "and T2 does not send a second one")
    }

    func testAnotherRadioClearingChangesNothing() {
        let clock = AX25VirtualClock()
        let (manager, _) = linkWithAFrameOwedAnAck(clock: clock)
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }

        manager.channelCleared(on: otherRadio)
        XCTAssertTrue(sent.isEmpty)
        clock.advance(by: 3)
        XCTAssertEqual(sent.filter { $0.frameType == "s" }.count, 1, "T2 still acks it")
    }

    func testAClearChannelWithNothingOwedSendsNothing() {
        let clock = AX25VirtualClock()
        let manager = AX25SessionManager(localCallsign: me, clock: clock)
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }
        _ = manager.handleInboundSABM(from: peer, to: me, path: DigiPath(), radio: modemRadio)
        manager.channelCleared(on: modemRadio)
        XCTAssertTrue(sent.isEmpty)
    }

    func testOnlyACarrierThatEndsCountsAsAClearChannel() {
        var busy = ModemTelemetry()
        busy.dcd = true
        var quiet = ModemTelemetry()
        quiet.dcd = false
        XCTAssertTrue(PacketEngine.channelCleared(from: busy, to: quiet))
        XCTAssertFalse(PacketEngine.channelCleared(from: quiet, to: quiet))
        XCTAssertFalse(PacketEngine.channelCleared(from: quiet, to: busy))
        XCTAssertFalse(PacketEngine.channelCleared(from: nil, to: quiet), "a first report is not a transition")
    }
}
