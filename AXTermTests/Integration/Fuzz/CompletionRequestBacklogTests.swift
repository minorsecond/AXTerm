//
//  CompletionRequestBacklogTests.swift
//  AXTermTests
//
//  A sender waiting for the receiver to confirm a file sends one completion
//  request at a time.
//
//  Smoke run 2026-10-03-1, issue 18: B (ID-50) ran stop-and-wait with about
//  3 s per acknowledged frame, and asked "do you have it all?" every 2 s.
//  Each request queued behind the last, A's confirmation arrived and the
//  transfer completed, and the queued requests kept going out: 13 for one
//  1 KB file, 45 for another, three minutes of channel.
//
//  Two complete stations over a link whose round trip is longer than the
//  request interval.
//

import XCTest
@testable import AXTerm

@MainActor
final class CompletionRequestBacklogTests: XCTestCase {

    func testCompletionRequestsDoNotPileUpOnASlowLink() async {
        let a = FuzzStation(callsign: "K0AAA-1", seed: 1)
        let b = FuzzStation(callsign: "K0BBB-2", seed: 2)
        defer { a.tearDown(); b.tearDown() }
        a.link.traceLimit = 10_000
        // Stop-and-wait with timers long enough for the slow link, so the
        // link layer itself does not resend.
        let slow = AX25SessionConfig(windowSize: 1, paclen: 128, maxRetries: 10,
                                     rtoMin: 6, rtoMax: 12, initialRto: 6,
                                     t2AckDelay: 0.1, adaptiveTimeout: false)
        for station in [a, b] {
            station.coordinator.sessionManager.getConfigForDestination = { _, _, _ in slow }
            station.coordinator.sessionManager.defaultConfig = slow
            // The harness's 10 s allowances are for its fast link.
            station.coordinator.transferTimeouts.awaitingCompletion = 120
            station.coordinator.transferTimeouts.outboundStall = 120
            station.coordinator.transferTimeouts.inboundStall = 120
        }
        a.connectLink(to: b)
        b.connectLink(to: a)
        if let sabm = a.coordinator.sessionManager.connect(to: b.address, path: DigiPath(),
                                                           radio: a.coordinator.primaryRadioID) {
            a.coordinator.sendFrame(sabm)
        }
        let up = await FullStackFuzz.wait(10) { a.session != nil && b.session != nil }
        XCTAssertTrue(up, "the link did not come up")
        a.coordinator.markImplicitlyConfirmedAXDP(for: b.callsign)
        b.coordinator.markImplicitlyConfirmedAXDP(for: a.callsign)

        // From here every frame takes 1.5 to 3 s to arrive: a round trip
        // longer than the 2 s between completion requests.
        a.link.impairment.jitter = 3
        b.link.impairment.jitter = 3

        let data = Data((0..<400).map { UInt8($0 % 251) })
        XCTAssertNil(a.coordinator.startTransfer(to: b.callsign, fileName: "SLOW.BIN", data: data,
                                                 transferProtocol: .axdp, compressionSettings: .disabled))
        let offered = await FullStackFuzz.wait(30) {
            b.coordinator.pendingIncomingTransfers.contains { $0.fileName == "SLOW.BIN" }
        }
        XCTAssertTrue(offered)
        if let offer = b.coordinator.pendingIncomingTransfers.first(where: { $0.fileName == "SLOW.BIN" }) {
            b.coordinator.acceptIncomingTransfer(offer.id)
        }
        let done = await FullStackFuzz.wait(90) { a.transfer(named: "SLOW.BIN")?.status == .completed }
        XCTAssertTrue(done, "the sender never completed: \(String(describing: a.transfer(named: "SLOW.BIN")?.status))")
        XCTAssertEqual(b.savedData(b.transfer(named: "SLOW.BIN")), data)

        // Let anything still queued go out.
        _ = await FullStackFuzz.wait(15) { false }

        // A completion request is the sender's only 24-byte AXDP message.
        let requests = a.link.trace.filter { $0.line.contains("> I s") && $0.line.contains(" 24B") }.count
        XCTAssertLessThanOrEqual(requests, 3, "\(requests) completion requests for one file")
    }
}
