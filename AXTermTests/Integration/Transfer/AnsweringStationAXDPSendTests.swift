//
//  AnsweringStationAXDPSendTests.swift
//  AXTermTests
//
//  Park rehearsal 2026-10-08, finding 29. The phone called A (705) and sent
//  no capability probe; A, which had answered the call, refused to send by
//  AXDP: "K0EPI-3 AXDP capability unknown. Connect first to discover
//  capabilities." The spec (6.x.3) says to negotiate when a transfer starts
//  and the peer's support is unknown, so the send asks and goes once the
//  peer answers.
//

import XCTest
@testable import AXTerm

@MainActor
final class AnsweringStationAXDPSendTests: XCTestCase {

    private var caller: TransferStation!
    private var answerer: TransferStation!
    private var file: URL!

    override func setUp() async throws {
        caller = TransferStation(callsign: "K0AAA-1")
        answerer = TransferStation(callsign: "K0BBB-2")
        // The caller never probes, as the phone didn't.
        caller.coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
        caller.coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = false
        answerer.coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
        answerer.coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
        caller.connectLink(to: answerer)
        answerer.connectLink(to: caller)

        if let sabm = caller.coordinator.sessionManager.connect(
            to: answerer.address, path: DigiPath(), radio: caller.coordinator.primaryRadioID) {
            caller.coordinator.sendFrame(sabm)
        }
        try await waitUntil("the link comes up") { self.caller.session != nil && self.answerer.session != nil }

        file = FileManager.default.temporaryDirectory.appendingPathComponent("answerer-\(UUID().uuidString).txt")
        try Data(repeating: 0x41, count: 300).write(to: file)
    }

    override func tearDown() async throws {
        if let file { try? FileManager.default.removeItem(at: file) }
        caller?.tearDown()
        answerer?.tearDown()
        try? await Task.sleep(nanoseconds: 50_000_000)
        caller = nil
        answerer = nil
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testTheAnsweringStationAsksAndThenSendsByAXDP() async throws {
        XCTAssertEqual(answerer.coordinator.capabilityStatus(for: caller.callsign), .unknown)

        let error = await answerer.coordinator.startTransfer(to: caller.callsign, fileURL: file,
                                                             compressionSettings: .disabled)

        XCTAssertNil(error)
        XCTAssertEqual(answerer.coordinator.capabilityStatus(for: caller.callsign), .confirmed)
        try await waitUntil("the caller is offered the file") {
            self.caller.coordinator.pendingIncomingTransfers.contains { $0.fileName == self.file.lastPathComponent }
        }
    }

    /// A station that never answers the check is treated as having no AXDP,
    /// and the refusal points to YAPP rather than saying to connect first.
    func testNoAnswerRefusesWithTheNoAXDPReason() async {
        // The caller stops answering probes.
        caller.coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = false
        var clock = Date()
        answerer.coordinator.capabilityWaitClock = {
            defer { clock = clock.addingTimeInterval(60) }
            return clock
        }

        let error = await answerer.coordinator.startTransfer(to: caller.callsign, fileURL: file,
                                                             compressionSettings: .disabled)

        XCTAssertNotNil(error)
        XCTAssertFalse(error?.contains("Connect first") ?? true, error ?? "")
        XCTAssertTrue(error?.contains("YAPP") ?? false, error ?? "")
        XCTAssertTrue(answerer.coordinator.transfers.isEmpty)
    }

    /// With auto-negotiation off, nothing new goes on the air.
    func testWithAutoNegotiationOffTheSendIsRefusedAsBefore() async {
        answerer.coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = false

        let error = await answerer.coordinator.startTransfer(to: caller.callsign, fileURL: file,
                                                             compressionSettings: .disabled)

        XCTAssertNotNil(error)
        XCTAssertEqual(answerer.coordinator.capabilityStatus(for: caller.callsign), .unknown)
    }
}
