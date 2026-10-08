//
//  PhotoSendChoiceTests.swift
//  AXTermTests
//
//  What a photo will be sent as, for the preview the operator sees before
//  sending (operator, 2026-10-07): the bytes that will go out, their size
//  and pixel size, and the original when that was asked for or a size
//  could not be reached.
//

import XCTest
@testable import AXTerm

final class PhotoSendChoiceTests: XCTestCase {
    private static let photo: Data = SyntheticPhoto.data(width: 3000, height: 2000, seed: 11)!

    func testTheOriginalGoesAsItIs() {
        let prepared = PhotoSendChoice.prepare(original: Self.photo, name: "IMG_2.HEIC", size: .original,
                                               format: .jpeg, keepsLocation: false)
        XCTAssertTrue(prepared.isOriginal)
        XCTAssertEqual(prepared.data, Self.photo)
        XCTAssertEqual(prepared.name, "IMG_2.HEIC")
        XCTAssertEqual(prepared.pixelWidth, 3000)
    }

    func testASizeGivesThePhotoThatWillBeSent() {
        let prepared = PhotoSendChoice.prepare(original: Self.photo, name: "IMG_2.HEIC", size: .small,
                                               format: .jpeg, keepsLocation: false)
        XCTAssertFalse(prepared.isOriginal)
        XCTAssertLessThanOrEqual(prepared.data.count, PhotoSendSize.small.byteBudget!)
        XCTAssertEqual(prepared.name, "IMG_2.jpg")
        XCTAssertLessThanOrEqual(max(prepared.pixelWidth, prepared.pixelHeight), 800)
        XCTAssertNil(prepared.note)
    }

    func testASizeThatCannotBeReachedSaysSoAndKeepsTheOriginal() {
        let tiny = PhotoSendChoice.prepare(original: Self.photo, name: "x.jpg", size: .small, format: .jpeg,
                                           keepsLocation: false, byteBudgetOverride: 200)
        XCTAssertTrue(tiny.isOriginal)
        XCTAssertNotNil(tiny.note)
    }
}
