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
        clock.advance(by: AX25SessionManager.channelQuietGrace)

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

    // MARK: A gap inside the peer's burst (retest 2026-10-10, finding 4)

    /// The carrier can drop between two frames of one burst, when the
    /// peer's TNC unkeys and keys again. A answered the first frame in that
    /// gap, keyed over the second, and lost it while the iPad lost the RR:
    /// nine times in a row, about 70 s. The ack now waits for the channel to
    /// stay quiet a moment.
    func testTheAckWaitsAMomentAfterTheChannelClears() {
        let clock = AX25VirtualClock()
        let (manager, _) = linkWithAFrameOwedAnAck(clock: clock)
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }

        manager.channelCleared(on: modemRadio)
        clock.advance(by: AX25SessionManager.channelQuietGrace / 2)
        XCTAssertTrue(sent.isEmpty, "not in the gap")
        clock.advance(by: AX25SessionManager.channelQuietGrace)
        XCTAssertEqual(sent.filter { $0.frameType == "s" }.count, 1)
    }

    func testACarrierThatComesBackKeepsTheAckHeld() {
        let clock = AX25VirtualClock()
        let (manager, _) = linkWithAFrameOwedAnAck(clock: clock)
        var sent: [OutboundFrame] = []
        manager.onSendFrame = { sent.append($0) }

        manager.channelCleared(on: modemRadio)
        clock.advance(by: 0.2)
        manager.channelBusy(on: modemRadio)   // the peer's next frame
        clock.advance(by: AX25SessionManager.channelQuietGrace)
        XCTAssertTrue(sent.isEmpty, "the peer is still sending")

        // The second frame arrives and its own clear sends the one RR.
        _ = manager.handleInboundIFrame(from: peer, to: me, path: DigiPath(), radio: modemRadio,
                                        ns: 1, nr: 0, pf: false, payload: Data("More\r".utf8))
        manager.channelCleared(on: modemRadio)
        clock.advance(by: AX25SessionManager.channelQuietGrace)
        let acks = sent.filter { $0.frameType == "s" }
        XCTAssertEqual(acks.count, 1)
    }

    /// The grace is far shorter than T2, or the early ack is pointless.
    func testTheGraceIsShortOfT2() {
        XCTAssertLessThan(AX25SessionManager.channelQuietGrace, 1.0)
        XCTAssertGreaterThanOrEqual(AX25SessionManager.channelQuietGrace, 0.5)
    }

    func testOnlyACarrierThatStartsCountsAsABusyChannel() {
        var busy = ModemTelemetry()
        busy.dcd = true
        var quiet = ModemTelemetry()
        quiet.dcd = false
        XCTAssertTrue(PacketEngine.channelBusy(from: quiet, to: busy))
        XCTAssertFalse(PacketEngine.channelBusy(from: busy, to: busy))
        XCTAssertFalse(PacketEngine.channelBusy(from: busy, to: quiet))
    }
}
