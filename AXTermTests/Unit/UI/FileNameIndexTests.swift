//
//  FileNameIndexTests.swift
//  AXTermTests
//
//  The Session view looked for spaced file names in every line of its
//  history on every redraw, about 0.4 s per 1,000 lines on the Mac and far
//  more on the phone, which became unbearably slow (park rehearsal
//  2026-10-08, after fix 36). A line's text does not change, so each text
//  is scanned once.
//

import XCTest
@testable import AXTerm

@MainActor
final class FileNameIndexTests: XCTestCase {

    private let listing = "NAME   SIZE  TIME\nBarro tal vez v11.fcpxml\n                   5K   <1m"

    func testEachTextIsScannedOnce() {
        var scans = 0
        let index = FileNameIndex { text in
            scans += 1
            return FileNameScanner.spacedNames(in: text)
        }
        let texts = ["RR(3) F", listing, "Welcome"]

        XCTAssertEqual(index.knownNames(in: texts), ["Barro tal vez v11.fcpxml"])
        XCTAssertEqual(index.knownNames(in: texts), ["Barro tal vez v11.fcpxml"])
        XCTAssertEqual(scans, 3, "the second redraw scans nothing")
    }

    /// A conversation block grows under the same id as lines join it, so the
    /// index goes by text.
    func testABlockThatGrewIsScannedAgain() {
        var scans = 0
        let index = FileNameIndex { text in
            scans += 1
            return FileNameScanner.spacedNames(in: text)
        }
        _ = index.knownNames(in: ["NAME   SIZE  TIME"])
        XCTAssertEqual(index.knownNames(in: [listing]), ["Barro tal vez v11.fcpxml"])
        XCTAssertEqual(scans, 2)
    }

    func testTextsNoLongerShownAreForgotten() {
        let index = FileNameIndex()
        for i in 0..<5_000 { _ = index.knownNames(in: ["line \(i)"]) }
        XCTAssertLessThanOrEqual(index.remembered, 1_000)
    }

    /// Most lines hold no listing at all, and a spaced name needs a line
    /// under it; a single line is skipped without the full scan.
    func testASingleLineHasNoSpacedNames() {
        XCTAssertEqual(FileNameScanner.spacedNames(in: "Barro tal vez v11.fcpxml sent."), [])
    }
}
