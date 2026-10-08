//
//  WinlinkPhotoSizeTests.swift
//  AXTermTests
//
//  Photos in a Winlink message from the field (operator, 2026-10-07): they
//  start at the medium size, about 25 KB, and the operator can pick another
//  size from the photo's preview; the message shows how long it will be on
//  the air.
//

import GRDB
import XCTest
@testable import AXTerm

@MainActor
final class WinlinkPhotoSizeTests: XCTestCase {
    private static let photo: Data = SyntheticPhoto.data(width: 3000, height: 2000, seed: 5)!

    private func makeViewModel() throws -> WinlinkComposeViewModel {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return WinlinkComposeViewModel(store: SQLiteWinlinkStore(dbQueue: queue), myCallsign: "K0EPI",
                                       existingDraftMID: nil, defaults: TestDefaults.make("WinlinkPhotoSize"))
    }

    func testAPhotoStartsAtTheMediumSize() {
        XCTAssertEqual(ComposeAttachmentPlanner.photoTargetBytes, PhotoSendSize.medium.byteBudget)
    }

    func testAPickedSizeReplacesThePhotoAndKeepsTheOriginal() async throws {
        let vm = try makeViewModel()
        await vm.addAttachments([ComposeIncomingFile(name: "IMG_3.HEIC", data: Self.photo)])
        let item = try XCTUnwrap(vm.attachments.first)
        let small = PhotoSendChoice.prepare(original: Self.photo, name: "IMG_3.HEIC", size: .small,
                                            format: .jpeg, keepsLocation: false)
        vm.applyPhoto(id: item.id, prepared: small)
        let applied = try XCTUnwrap(vm.attachments.first)
        XCTAssertEqual(applied.id, item.id)
        XCTAssertEqual(applied.data, small.data)
        XCTAssertEqual(applied.name, "IMG_3.jpg")
        XCTAssertEqual(applied.original?.data, Self.photo, "Send Original still has the original")
        XCTAssertTrue(applied.isShrunk)
    }

    func testTheMessageSaysHowLongItIsOnTheAir() throws {
        XCTAssertEqual(AirtimeHint.short(bytes: 36_000, measuredBytesPerSecond: nil), "~10 min on air")
        XCTAssertEqual(AirtimeHint.short(bytes: 1_000, measuredBytesPerSecond: nil), "<1 min on air")
    }
}
