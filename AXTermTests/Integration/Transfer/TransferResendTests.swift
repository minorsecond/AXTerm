//
//  TransferResendTests.swift
//  AXTermTests
//
//  Home retest 2026-10-10, findings 5 and 10. A file that failed or was
//  declined could only be sent again by picking it again. The operator
//  asked for Send Again in the transfer list, confirmed first. A mailbox
//  that takes uploads by YAPP only declines an AXDP offer, and the row then
//  offers to send the same file by YAPP.
//

import XCTest
@testable import AXTerm

@MainActor
final class TransferResendTests: XCTestCase {

    private var sender: TransferStation!
    private var receiver: TransferStation!
    private let bytes = Data(repeating: 0x42, count: 300)
    private var file: URL!

    override func setUp() async throws {
        sender = TransferStation(callsign: "K0AAA-1")
        receiver = TransferStation(callsign: "K0BBB-2")
        // As in AnsweringStationAXDPSendTests: the receiver calls without a
        // probe, and the sender asks when the transfer starts.
        receiver.coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
        receiver.coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = false
        sender.coordinator.globalAdaptiveSettings.axdpExtensionsEnabled = true
        sender.coordinator.globalAdaptiveSettings.autoNegotiateCapabilities = true
        receiver.connectLink(to: sender)
        sender.connectLink(to: receiver)
        if let sabm = receiver.coordinator.sessionManager.connect(
            to: sender.address, path: DigiPath(), radio: receiver.coordinator.primaryRadioID) {
            receiver.coordinator.sendFrame(sabm)
        }
        try await waitUntil("the link comes up") { self.sender.session != nil && self.receiver.session != nil }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("resend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("photo.jpg")
        try bytes.write(to: file)
    }

    override func tearDown() async throws {
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        sender?.tearDown()
        receiver?.tearDown()
        try? await Task.sleep(nanoseconds: 50_000_000)
        sender = nil
        receiver = nil
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

    /// Offers the file by AXDP and has the receiver decline it.
    private func sendAndDecline() async throws -> BulkTransfer {
        let error = await sender.coordinator.startTransfer(to: receiver.callsign, fileURL: file,
                                                           compressionSettings: .disabled)
        XCTAssertNil(error)
        try await waitUntil("the receiver is offered the file") {
            !self.receiver.coordinator.pendingIncomingTransfers.isEmpty
        }
        let offer = try XCTUnwrap(receiver.coordinator.pendingIncomingTransfers.first)
        receiver.coordinator.declineIncomingTransfer(offer.id, reason: "YAPP only")
        try await waitUntil("the sender hears it was declined") {
            self.sender.coordinator.transfers.first?.wasDeclined == true
        }
        return try XCTUnwrap(sender.coordinator.transfers.first)
    }

    func testARunningTransferCannotBeSentAgain() async throws {
        let error = await sender.coordinator.startTransfer(to: receiver.callsign, fileURL: file,
                                                           compressionSettings: .disabled)
        XCTAssertNil(error)
        let row = try XCTUnwrap(sender.coordinator.transfers.first)
        XCTAssertTrue(sender.coordinator.resendChoices(for: row.id).isEmpty)
    }

    func testADeclinedAXDPTransferOffersAgainAndByYAPP() async throws {
        let row = try await sendAndDecline()
        XCTAssertEqual(sender.coordinator.resendChoices(for: row.id), [.axdp, .yapp])
        XCTAssertTrue(sender.coordinator.offersYAPPInstead(for: row.id))
    }

    /// Send with YAPP Instead starts the same file to the same station by
    /// YAPP, as a new row; the declined row stays as it was.
    func testSendingWithYAPPInsteadStartsTheSameFileByYAPP() async throws {
        let row = try await sendAndDecline()
        XCTAssertNil(sender.coordinator.resend(row.id, using: .yapp))
        XCTAssertEqual(sender.coordinator.transfers.count, 2)
        let again = try XCTUnwrap(sender.coordinator.transfers.last)
        XCTAssertNotEqual(again.id, row.id)
        XCTAssertEqual(again.fileName, "photo.jpg")
        XCTAssertEqual(again.fileSize, bytes.count)
        XCTAssertEqual(again.destination.uppercased(), receiver.callsign.uppercased())
        XCTAssertEqual(again.transferProtocol, .yapp)
        XCTAssertTrue(sender.coordinator.transfers.first?.wasDeclined == true)
    }

    func testSendAgainUsesTheSameProtocol() async throws {
        let row = try await sendAndDecline()
        XCTAssertNil(sender.coordinator.resend(row.id))
        XCTAssertEqual(sender.coordinator.transfers.last?.transferProtocol, .axdp)
        try await waitUntil("the receiver is offered it again") {
            !self.receiver.coordinator.pendingIncomingTransfers.isEmpty
        }
    }

    /// A received file is not ours to send again.
    func testAReceivedFileHasNoSendAgain() async throws {
        _ = try await sendAndDecline()
        for row in receiver.coordinator.transfers {
            XCTAssertTrue(receiver.coordinator.resendChoices(for: row.id).isEmpty)
        }
    }

    /// With the link down there is nothing to send it over.
    func testNoSendAgainWithoutTheLink() async throws {
        let row = try await sendAndDecline()
        let session = try XCTUnwrap(sender.session)
        if let disc = sender.coordinator.sessionManager.disconnect(session: session) {
            sender.coordinator.sendFrame(disc)
        }
        try await waitUntil("the link goes down") { self.sender.session == nil }
        XCTAssertFalse(sender.coordinator.offersYAPPInstead(for: row.id))
        XCTAssertNotNil(sender.coordinator.resend(row.id, using: .yapp), "says why it cannot")
    }
}
