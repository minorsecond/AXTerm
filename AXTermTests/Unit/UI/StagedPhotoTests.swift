//
//  StagedPhotoTests.swift
//  AXTermTests
//
//  A photo shrunk in Send File goes in place of the picked file, staged the
//  same way, and is cleaned up the same way (operator, 2026-10-07).
//

import XCTest
@testable import AXTerm

final class StagedPhotoTests: XCTestCase {

    func testShrunkBytesAreStagedUnderTheirOwnNameAndDiscarded() throws {
        let bytes = Data(repeating: 0xAB, count: 1234)
        let url = try OutgoingFileStaging.stage(data: bytes, name: "IMG_2.jpg")
        XCTAssertEqual(url.lastPathComponent, "IMG_2.jpg")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        OutgoingFileStaging.discard(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
