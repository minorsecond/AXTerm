//
//  Base64DownloadTests.swift
//  AXTermTests
//
//  A binary file over a link that carries only lines (Docs/RemoteAccessPlan.md,
//  part 2): the mailbox types it as base64 between the same BEGIN and END
//  lines a text file gets, with ", base64" after the count. Any computer
//  decodes base64 (`base64 -d`), and AXTerm rebuilds the file itself.
//

import XCTest
@testable import AXTerm

final class Base64DownloadTests: XCTestCase {

    private let binary = Data((0..<300).map { UInt8(($0 * 37 + 11) & 0xFF) })

    func testABinaryFileGoesAsBase64Lines() throws {
        let lines = TextDownloadMarkers.markedBase64Lines(name: "photo.jpg", data: binary)
        XCTAssertEqual(lines.first, "--- BEGIN photo.jpg (300 bytes, base64) ---")
        XCTAssertEqual(lines.last, "--- END photo.jpg ---")
        let body = lines.dropFirst().dropLast()
        XCTAssertTrue(body.allSatisfy { $0.count <= 76 })
        XCTAssertEqual(Data(base64Encoded: body.joined()), binary)
    }

    func testTheBase64BeginLineParses() throws {
        let begin = try XCTUnwrap(TextDownloadMarkers.parseBegin("--- BEGIN my photo (1).jpg (300 bytes, base64) ---"))
        XCTAssertEqual(begin.name, "my photo (1).jpg")
        XCTAssertEqual(begin.byteCount, 300)
        XCTAssertTrue(begin.isBase64)
        XCTAssertFalse(try XCTUnwrap(TextDownloadMarkers.parseBegin("--- BEGIN a.txt (3 bytes) ---")).isBase64)
        XCTAssertNil(TextDownloadMarkers.parseBegin("--- BEGIN a.bin (3 bytes, rot13) ---"))
    }

    private func feed(_ lines: [String]) -> [TextDownloadReceiver.Result] {
        var receiver = TextDownloadReceiver()
        return lines.compactMap { receiver.receive(line: Data($0.utf8)) }
    }

    func testAXTermRebuildsTheFile() {
        let results = feed(TextDownloadMarkers.markedBase64Lines(name: "photo.jpg", data: binary))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.data, binary)
        XCTAssertNil(results.first?.problem)
    }

    func testAMissingLineIsReported() {
        var lines = TextDownloadMarkers.markedBase64Lines(name: "photo.jpg", data: binary)
        lines.remove(at: 2)
        let result = feed(lines).first
        XCTAssertNotNil(result?.problem)
        XCTAssertLessThan(result?.data.count ?? 0, binary.count)
    }

    func testTheLinkClosingMidFileReportsIt() {
        var receiver = TextDownloadReceiver()
        let lines = TextDownloadMarkers.markedBase64Lines(name: "photo.jpg", data: binary)
        for line in lines.prefix(3) { _ = receiver.receive(line: Data(line.utf8)) }
        XCTAssertNotNil(receiver.linkClosed()?.problem)
    }
}
