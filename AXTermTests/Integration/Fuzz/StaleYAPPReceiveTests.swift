//
//  StaleYAPPReceiveTests.swift
//  AXTermTests
//
//  A YAPP receive whose sender is gone must not swallow what the other
//  station sends next.
//
//  A packet holding just YAPP's SI starts a receive, and the receive takes
//  the session's byte stream while it waits for the header. If the sender
//  never sends one (its YAPP program died, or a link reset that only the
//  sender was told about ended its transfer, spec §7.1.1), the receive
//  waits out its response timeout: 120 s in the app. Suspected in the
//  full-stack fuzz, seed 3034 (2026-10-02): an AXDP offer reached B at the
//  link layer just after a reset and was never shown.
//
//  Two complete stations over a clean link: A sends SI alone, then chat
//  and an AXDP offer.
//

import XCTest
@testable import AXTerm

@MainActor
final class StaleYAPPReceiveTests: XCTestCase {

    private func connectedPair() async -> (FuzzStation, FuzzStation) {
        let a = FuzzStation(callsign: "K0AAA-1", seed: 1)
        let b = FuzzStation(callsign: "K0BBB-2", seed: 2)
        a.connectLink(to: b)
        b.connectLink(to: a)
        // The app's own wait for a YAPP header.
        b.coordinator.yappResponseTimeout = 120
        if let sabm = a.coordinator.sessionManager.connect(to: b.address, path: DigiPath(),
                                                           radio: a.coordinator.primaryRadioID) {
            a.coordinator.sendFrame(sabm)
        }
        let up = await FullStackFuzz.wait(10) { a.session != nil && b.session != nil }
        XCTAssertTrue(up, "the link did not come up")
        a.coordinator.markImplicitlyConfirmedAXDP(for: b.callsign)
        b.coordinator.markImplicitlyConfirmedAXDP(for: a.callsign)
        return (a, b)
    }

    private func send(_ data: Data, from a: FuzzStation, to b: FuzzStation) {
        for frame in a.coordinator.sessionManager.sendData(data, to: b.address, radio: a.coordinator.primaryRadioID) {
            a.coordinator.sendFrame(frame)
        }
    }

    /// A's YAPP program sent SI and went away. B is waiting for a header.
    private func strandYAPPReceive(_ a: FuzzStation, _ b: FuzzStation) async {
        send(YAPPEncoder.sendInit(), from: a, to: b)
        let waiting = await FullStackFuzz.wait(5) { !b.coordinator.yappAwaitingHeader.isEmpty }
        XCTAssertTrue(waiting, "SI did not start a YAPP receive on B")
    }

    func testChatAfterAStrandedYAPPStartReachesTheTerminal() async {
        let (a, b) = await connectedPair()
        defer { a.tearDown(); b.tearDown() }
        await strandYAPPReceive(a, b)

        send(Data("are you there?\r".utf8), from: a, to: b)
        let arrived = await FullStackFuzz.wait(5) {
            b.terminalText.range(of: Data("are you there?".utf8)) != nil
        }
        XCTAssertTrue(arrived, "the chat line went into the waiting YAPP receive")
        XCTAssertTrue(b.coordinator.yappAwaitingHeader.isEmpty, "the stranded receive still holds the session")
        // A is not running YAPP; a CN (0x18) from B would print in its terminal.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(a.terminalText.contains(0x18),
                       "B sent a YAPP cancel to a station not running YAPP: \(Array(a.terminalText))")
    }

    func testAnAXDPOfferAfterAStrandedYAPPStartIsShown() async {
        let (a, b) = await connectedPair()
        defer { a.tearDown(); b.tearDown() }
        await strandYAPPReceive(a, b)

        let error = a.coordinator.startTransfer(to: b.callsign, fileName: "OFFER.BIN", data: Data(repeating: 7, count: 300),
                                                transferProtocol: .axdp, compressionSettings: .disabled)
        XCTAssertNil(error)
        let offered = await FullStackFuzz.wait(8) {
            b.coordinator.pendingIncomingTransfers.contains { $0.fileName == "OFFER.BIN" }
        }
        XCTAssertTrue(offered, "the AXDP offer went into the waiting YAPP receive")
    }

    /// A real YAPP transfer still works: SI, then the header, then the file.
    func testARealYAPPTransferIsUnaffected() async {
        let (a, b) = await connectedPair()
        defer { a.tearDown(); b.tearDown() }
        let data = Data((0..<500).map { UInt8($0 % 251) })
        XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: "REAL.BIN", data: data,
                                                 transferProtocol: .yapp, compressionSettings: .disabled))
        let offered = await FullStackFuzz.wait(10) {
            b.coordinator.pendingIncomingTransfers.contains { $0.fileName == "REAL.BIN" }
        }
        XCTAssertTrue(offered)
        if let offer = b.coordinator.pendingIncomingTransfers.first(where: { $0.fileName == "REAL.BIN" }) {
            b.coordinator.acceptIncomingTransfer(offer.id)
        }
        let done = await FullStackFuzz.wait(20) { b.transfer(named: "REAL.BIN")?.status == .completed }
        XCTAssertTrue(done)
        XCTAssertEqual(b.savedData(b.transfer(named: "REAL.BIN")), data)
    }
}
