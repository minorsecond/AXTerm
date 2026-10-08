//
//  PhotoSendSizeTests.swift
//  AXTermTests
//
//  Photos from a field test, sent over packet and Winlink (operator,
//  2026-10-07). A phone photo is several megabytes and a 1200-baud link
//  moves about 60 bytes a second, so the operator picks a size with its
//  airtime in view: small, medium, large or the original, as JPEG, which
//  opens everywhere, or HEIC, which looks the same in less airtime when the
//  other end is an Apple device.
//

import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AXTerm

final class PhotoSendSizeTests: XCTestCase {
    private static let photo: Data = SyntheticPhoto.data(width: 3000, height: 2000, seed: 7)!

    func testEachSizeFitsItsBudget() throws {
        for size in [PhotoSendSize.small, .medium, .large] {
            let options = try XCTUnwrap(size.options(format: .jpeg, keepsLocation: false))
            guard case .success(.shrunk(let shrunk)) = ImageShrinker.shrink(Self.photo, name: "IMG_1.HEIC",
                                                                             options: options) else {
                return XCTFail("\(size) did not shrink")
            }
            XCTAssertLessThanOrEqual(shrunk.data.count, options.byteBudget, "\(size)")
            XCTAssertLessThanOrEqual(max(shrunk.pixelWidth, shrunk.pixelHeight), options.maxLongEdge)
        }
        XCTAssertNil(PhotoSendSize.original.options(format: .jpeg, keepsLocation: false))
    }

    func testTheSizesGrow() {
        XCTAssertLessThan(PhotoSendSize.small.byteBudget!, PhotoSendSize.medium.byteBudget!)
        XCTAssertLessThan(PhotoSendSize.medium.byteBudget!, PhotoSendSize.large.byteBudget!)
    }

    func testHEICComesOutAsHEICAndNamedSo() throws {
        let options = try XCTUnwrap(PhotoSendSize.medium.options(format: .heic, keepsLocation: false))
        guard case .success(.shrunk(let shrunk)) = ImageShrinker.shrink(Self.photo, name: "IMG_1.JPG",
                                                                         options: options) else {
            return XCTFail("did not shrink")
        }
        XCTAssertEqual(shrunk.name, "IMG_1.heic")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(shrunk.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.heic.identifier)
    }

    func testASlowLinkStartsSmall() {
        XCTAssertEqual(PhotoSendSize.suggested(bytesPerSecond: nil), .small)
        XCTAssertEqual(PhotoSendSize.suggested(bytesPerSecond: 60), .small)
        XCTAssertEqual(PhotoSendSize.suggested(bytesPerSecond: 1_000), .large)
    }

    // MARK: Airtime

    func testAMeasuredRateIsUsedAndSaidSo() throws {
        let hint = try XCTUnwrap(AirtimeHint.make(bytes: 24_000, measuredBytesPerSecond: 80, peer: "K0EPI-2"))
        XCTAssertEqual(hint.seconds, 300, accuracy: 0.5)
        XCTAssertEqual(hint.text, "about 5 minutes on the air at the rate of your last transfer with K0EPI-2")
    }

    func testWithoutOneTheTypicalRateIsUsedAndSaidSo() throws {
        let hint = try XCTUnwrap(AirtimeHint.make(bytes: 36_000, measuredBytesPerSecond: nil, peer: nil))
        XCTAssertEqual(hint.seconds, 600, accuracy: 0.5)
        XCTAssertEqual(hint.text, "about 10 minutes on the air at a typical 1200-baud rate")
    }
}
