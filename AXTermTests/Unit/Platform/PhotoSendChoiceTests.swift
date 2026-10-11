//
//  PhotoSendChoiceTests.swift
//  AXTermTests
//
//  What a photo will be sent as, for the preview the operator sees before
//  sending (operator, 2026-10-07): the bytes that will go out, their size
//  and pixel size, and the original when that was asked for or a size
//  could not be reached.
//

import UniformTypeIdentifiers
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

    /// Operator, 2026-10-11: the preview gives both sizes, so the choice
    /// between HEIC and JPEG is made on the bytes, not on a label.
    func testTheOtherFormatIsPricedForComparison() throws {
        guard SyntheticPhoto.data(width: 64, height: 64, type: .heic) != nil else {
            throw XCTSkip("this machine cannot encode HEIC")
        }
        // A budget neither needs, so both are at the size's full resolution.
        let prepared = PhotoSendChoice.prepare(original: Self.photo, name: "IMG_2.HEIC", size: .large,
                                               format: .heic, keepsLocation: false,
                                               byteBudgetOverride: 1024 * 1024, comparesFormats: true)
        XCTAssertEqual(prepared.format, .heic)
        let other = try XCTUnwrap(prepared.alternative)
        XCTAssertEqual(other.format, .jpeg)
        XCTAssertEqual(other.pixelWidth, prepared.pixelWidth)
        XCTAssertGreaterThan(other.byteCount, prepared.data.count)
        XCTAssertEqual(prepared.formatComparison,
                       "\(ByteCount.string(prepared.data.count)) as HEIC "
                           + "(JPEG would be \(ByteCount.string(other.byteCount)))")
    }

    /// Under a tight budget the other format may only fit as a smaller
    /// picture, and the comparison says so.
    func testTheComparisonGivesTheOtherPixelSizeWhenItDiffers() {
        let prepared = PhotoSendChoice.Prepared(
            data: Data(count: 25_000), name: "a.heic", pixelWidth: 1024, pixelHeight: 683, isOriginal: false,
            note: nil, format: .heic,
            alternative: .init(format: .jpeg, byteCount: 25_500, pixelWidth: 655, pixelHeight: 437))
        XCTAssertEqual(prepared.formatComparison,
                       "\(ByteCount.string(25_000)) as HEIC (JPEG would be \(ByteCount.string(25_500)) at 655 × 437 px)")
    }

    func testNoComparisonUnlessAskedOrForTheOriginal() {
        let plain = PhotoSendChoice.prepare(original: Self.photo, name: "a.jpg", size: .small, format: .jpeg,
                                            keepsLocation: false)
        XCTAssertNil(plain.alternative)
        XCTAssertNil(plain.formatComparison)
        let original = PhotoSendChoice.prepare(original: Self.photo, name: "a.jpg", size: .original,
                                               format: .heic, keepsLocation: false, comparesFormats: true)
        XCTAssertNil(original.alternative)
        XCTAssertNil(original.format)
    }

    func testASizeThatCannotBeReachedSaysSoAndKeepsTheOriginal() {
        let tiny = PhotoSendChoice.prepare(original: Self.photo, name: "x.jpg", size: .small, format: .jpeg,
                                           keepsLocation: false, byteBudgetOverride: 200)
        XCTAssertTrue(tiny.isOriginal)
        XCTAssertNotNil(tiny.note)
    }
}
