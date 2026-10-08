//
//  SendFilePhotoLibraryTests.swift
//  AXTermTests
//
//  Send File on the phone and iPad takes a photo from the photo library as
//  well as a file from Files (operator, 2026-10-08: "it should be able to
//  send from the photos picker or the files app depending on what is being
//  sent"). Library photos arrive as bytes with no name, so each is named and
//  staged like a picked file, then goes through the same send sheet.
//

import XCTest
import UniformTypeIdentifiers
@testable import AXTerm

final class SendFilePhotoLibraryTests: XCTestCase {
    private let denver = TimeZone(identifier: "America/Denver")!
    /// 2026-10-08 14:42:10 UTC, 08:42:10 in Denver.
    private let when = Date(timeIntervalSince1970: 1_791_470_530)

    func testAPhotoIsNamedForWhenItWasPickedWithItsOwnExtension() {
        XCTAssertEqual(PickedPhotos.name(index: 0, of: 1, contentType: .heic, at: when, timeZone: denver),
                       "Photo-20261008-084210.heic")
        XCTAssertEqual(PickedPhotos.name(index: 0, of: 1, contentType: nil, at: when, timeZone: denver),
                       "Photo-20261008-084210.jpg", "no type known: JPEG, the common case")
    }

    func testSeveralPhotosPickedTogetherGetTheirOwnNames() {
        let names = (0..<3).map { PickedPhotos.name(index: $0, of: 3, contentType: .jpeg, at: when, timeZone: denver) }
        XCTAssertEqual(names, ["Photo-20261008-084210-1.jpeg", "Photo-20261008-084210-2.jpeg",
                               "Photo-20261008-084210-3.jpeg"])
    }

    func testPhotosAreStagedForTheSendSheetAndAnUnreadableOneIsNamed() throws {
        let bytes = Data(repeating: 0x42, count: 2048)
        let result = PickedPhotos.stage([(bytes, .heic), (nil, .jpeg)], at: when, timeZone: denver)
        defer { result.urls.forEach(OutgoingFileStaging.discard) }

        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["Photo-20261008-084210-1.heic"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.urls.first)), bytes)
        XCTAssertEqual(result.failed, ["Photo-20261008-084210-2.jpeg"])
    }
}
