//
//  ReceivedFileNoticeTests.swift
//  AXTermTests
//
//  A file that arrives is announced where the operator is, with a way to
//  open it (park rehearsal 2026-10-08, finding 25): until now it showed only
//  on its Transfers row, and the system notification, sent only in the
//  background, could not open it.
//

import XCTest
@testable import AXTerm

@MainActor
final class ReceivedFileNoticeTests: XCTestCase {

    private func transfer(direction: TransferDirection, status: BulkTransferStatus,
                          saved: String? = "/tmp/AXTerm Transfers/IMG_2820.jpg") -> BulkTransfer {
        var t = BulkTransfer(id: UUID(), fileName: "IMG_2820.jpg", fileSize: 24_150, destination: "K0EPI-4",
                             direction: direction)
        t.status = status
        t.savedFilePath = saved
        return t
    }

    func testAFileThatArrivesIsAnnounced() {
        let coordinator = SessionCoordinator()
        var notices: [ReceivedFileNotice] = []
        coordinator.onFileReceived = { notices.append($0) }
        let running = transfer(direction: .inbound, status: .sending)
        coordinator.transfers = [running]
        var done = running
        done.status = .completed
        coordinator.transfers = [done]

        XCTAssertEqual(notices.map(\.fileName), ["IMG_2820.jpg"])
        XCTAssertEqual(notices.first?.peer, "K0EPI-4")
        XCTAssertEqual(notices.first?.path, "/tmp/AXTerm Transfers/IMG_2820.jpg")
        XCTAssertEqual(notices.first?.title, "IMG_2820.jpg received from K0EPI-4")
    }

    func testOnlyAFileThatArrivedAndWasSavedIsAnnounced() {
        let coordinator = SessionCoordinator()
        var notices: [ReceivedFileNotice] = []
        coordinator.onFileReceived = { notices.append($0) }
        for (direction, status, saved) in [(TransferDirection.outbound, BulkTransferStatus.completed, "/tmp/x"),
                                           (.inbound, .failed(reason: "link lost"), "/tmp/x"),
                                           (.inbound, .completed, nil)] {
            var t = transfer(direction: direction, status: .sending, saved: saved)
            coordinator.transfers = [t]
            t.status = status
            coordinator.transfers = [t]
        }
        XCTAssertTrue(notices.isEmpty, "sent, failed or unsaved files are not announced as received")
    }

    func testTheRouterHoldsOneNoticeUntilItIsDismissed() {
        let router = TransferUIRouter()
        let notice = ReceivedFileNotice(fileName: "a.jpg", peer: "K0EPI-4", path: "/tmp/a.jpg")
        router.announceReceived(notice)
        XCTAssertEqual(router.receivedFile, notice)
        router.dismissReceived(notice)
        XCTAssertNil(router.receivedFile)
    }

    func testDismissingAnOlderNoticeLeavesANewerOne() {
        let router = TransferUIRouter()
        let older = ReceivedFileNotice(fileName: "a.jpg", peer: "K0EPI-4", path: "/tmp/a.jpg")
        let newer = ReceivedFileNotice(fileName: "b.jpg", peer: "K0EPI-4", path: "/tmp/b.jpg")
        router.announceReceived(older)
        router.announceReceived(newer)
        router.dismissReceived(older)
        XCTAssertEqual(router.receivedFile, newer, "an older banner's timer must not close a newer one")
    }

    func testTheNotificationCarriesTheFileSoTappingItCanShowIt() {
        let info = TransferNotificationPolicy.userInfo(
            for: .completed(fileName: "a.jpg", peer: "K0EPI-4", direction: .inbound), path: "/tmp/a.jpg")
        XCTAssertEqual(info[NotificationAction.receivedFilePathKey] as? String, "/tmp/a.jpg")
        XCTAssertTrue(TransferNotificationPolicy.userInfo(
            for: .completed(fileName: "a.jpg", peer: "K0EPI-4", direction: .outbound), path: "/tmp/a.jpg").isEmpty,
                      "only a file that arrived is opened from its notification")
    }
}
