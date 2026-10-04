//
//  InboundSizeEstimateTests.swift
//  AXTermTests
//
//  What a receiver expects to receive, before any of it arrives.
//
//  Smoke run 2026-10-03-1, item 4 of the night's list: B (ID-50) showed
//  "21 KB" for a 20 KB file. The receiver took chunks × chunk size, which
//  is right only when the last chunk is full, and 720-byte chunks overshoot
//  by up to 719 bytes. FILE_META carries the original size, which is exact
//  when nothing is compressed.
//

import XCTest
@testable import AXTerm

final class InboundSizeEstimateTests: XCTestCase {

    func testAnUncompressedFileIsItsOwnSize() {
        XCTAssertEqual(BulkTransfer.expectedInboundBytes(fileSize: 20_480, chunks: 29, chunkSize: 720,
                                                         compressed: false), 20_480)
    }

    /// Compressed, only the chunk count is known: at most a full last chunk.
    func testACompressedFileIsBoundedByItsChunks() {
        XCTAssertEqual(BulkTransfer.expectedInboundBytes(fileSize: 20_480, chunks: 12, chunkSize: 720,
                                                         compressed: true), 8_640)
    }
}
