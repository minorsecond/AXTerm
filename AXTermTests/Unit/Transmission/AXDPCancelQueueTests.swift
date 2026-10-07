//
//  AXDPCancelQueueTests.swift
//  AXTermTests
//
//  An AXDP cancel goes ahead of a chunk that is still queued whole.
//
//  Smoke run 2026-10-03-1, issue 52: B (ID-50) canceled a transfer to A
//  (705) at 15:01:33Z, a moment after its chunk loop had handed the session
//  a 768-byte chunk. None of it was on the air yet, but the NACK queued
//  behind its twelve 64-byte frames and went out 37 s later. Issue 19 fixed
//  the same thing for YAPP.
//

import XCTest
@testable import AXTerm

@MainActor
final class AXDPCancelQueueTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 3)

    private func station() throws -> (TransferStation, AX25Session) {
        let station = TransferStation(callsign: "K0EPI-2")
        let slow = AX25SessionConfig(windowSize: 1, paclen: 64, maxRetries: 3, initialRto: 3.0,
                                     adaptiveTimeout: false)
        station.coordinator.sessionManager.getConfigForDestination = { _, _, _ in slow }
        station.coordinator.sessionManager.defaultConfig = slow
        _ = station.coordinator.sessionManager.handleInboundSABM(
            from: peer, to: station.address, path: DigiPath(), radio: .primary)
        let session = try XCTUnwrap(station.coordinator.sessionManager.connectedSession(withPeer: peer))
        return (station, session)
    }

    /// An outbound AXDP transfer to the peer, one chunk handed to a session
    /// whose window is already full.
    private func transferWithAChunkQueued(on station: TransferStation, session: AX25Session) -> UUID {
        let c = station.coordinator
        // One frame outstanding fills the K=1 window.
        XCTAssertEqual(c.sessionManager.sendData(Data(repeating: 0x41, count: 40), to: peer).count, 1)
        let id = UUID()
        var transfer = BulkTransfer(id: id, fileName: "t20k_bin.bin", fileSize: 2048,
                                    destination: peer.display, chunkSize: 512)
        transfer.status = .sending
        c.transfers.append(transfer)
        c.transferFileData[id] = Data(repeating: 0x5A, count: 2048)
        c.transferSessionIds[id] = 7
        c.transferRoutes[id] = TransferRoute(destination: peer, path: DigiPath())
        c.sendNextChunk(for: id, to: peer, path: DigiPath(), axdpSessionId: 7)
        return id
    }

    func testACancelDropsAChunkThatIsStillQueuedWhole() throws {
        let (station, session) = try station()
        defer { station.tearDown() }
        let id = transferWithAChunkQueued(on: station, session: session)
        XCTAssertGreaterThan(session.pendingDataQueue.count, 1, "the chunk waits whole behind the full window")

        station.coordinator.cancelTransfer(id)

        XCTAssertEqual(session.pendingDataQueue.count, 1, "only the NACK is queued")
        let queued = try XCTUnwrap(session.pendingDataQueue.first)
        let (message, _) = try XCTUnwrap(AXDP.Message.decode(from: queued.data))
        XCTAssertEqual(message.type, .nack)
        XCTAssertEqual(session.sendBuffer.count, 1, "the numbered frame is still owed to the peer")
    }

    func testACancelLeavesAChunkAlreadyOnTheAir() throws {
        let (station, session) = try station()
        defer { station.tearDown() }
        let c = station.coordinator
        let id = UUID()
        var transfer = BulkTransfer(id: id, fileName: "t20k_bin.bin", fileSize: 2048,
                                    destination: peer.display, chunkSize: 512)
        transfer.status = .sending
        c.transfers.append(transfer)
        c.transferFileData[id] = Data(repeating: 0x5A, count: 2048)
        c.transferSessionIds[id] = 7
        c.transferRoutes[id] = TransferRoute(destination: peer, path: DigiPath())
        // The window is open: the chunk's first frame goes on the air.
        c.sendNextChunk(for: id, to: peer, path: DigiPath(), axdpSessionId: 7)
        let rest = session.pendingDataQueue.count
        XCTAssertGreaterThan(rest, 0)

        c.cancelTransfer(id)

        XCTAssertEqual(session.pendingDataQueue.count, rest + 1,
                       "the rest of a chunk already started is still sent, then the NACK")
    }

    // Smoke run 2026-10-03-1, test 13.3, issue 105: after the phone canceled
    // at 12:40:03, A (705) kept sending queued 64-byte frames until 12:40:33,
    // and through a 30 s pause it kept sending one every 3 s.

    func testTheReceiverCancelingDropsAChunkThatIsStillQueuedWhole() throws {
        let (station, session) = try station()
        defer { station.tearDown() }
        let id = transferWithAChunkQueued(on: station, session: session)
        XCTAssertGreaterThan(session.pendingDataQueue.count, 1)

        let nack = AXDP.Message(type: .nack, sessionId: 7, messageId: 1)
        station.coordinator.handleNackMessage(nack, from: peer)

        XCTAssertEqual(station.coordinator.transfers.first { $0.id == id }?.status, .cancelled)
        XCTAssertTrue(session.pendingDataQueue.isEmpty, "nothing more goes out for a canceled transfer")
        XCTAssertEqual(session.sendBuffer.count, 1, "the numbered frame is still owed to the peer")
    }

    func testAPauseDropsAChunkStillQueuedWholeAndResumeSendsItAgain() throws {
        let (station, session) = try station()
        defer { station.tearDown() }
        let c = station.coordinator
        let id = transferWithAChunkQueued(on: station, session: session)
        XCTAssertGreaterThan(session.pendingDataQueue.count, 1)

        c.pauseTransfer(id)

        XCTAssertTrue(session.pendingDataQueue.isEmpty, "a pause stops what has not gone on the air")
        let paused = try XCTUnwrap(c.transfers.first { $0.id == id })
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.nextChunkToSend, 0, "the dropped chunk is owed again")

        c.resumeTransfer(id)

        // The chunk loop turn scheduled before the pause carries on now the
        // status is Sending again; it runs on the next tick.
        let deadline = Date().addingTimeInterval(2)
        while session.pendingDataQueue.count <= 1, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertGreaterThan(session.pendingDataQueue.count, 1, "resume hands the same chunk over again")
        // Queued as 64-byte segments; the first carries the chunk's label.
        XCTAssertEqual(session.pendingDataQueue.first?.displayInfo, "AXDP CHUNK 1/4")
    }
}
