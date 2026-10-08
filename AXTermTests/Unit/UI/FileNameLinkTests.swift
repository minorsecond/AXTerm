//
//  FileNameLinkTests.swift
//  AXTermTests
//
//  Park rehearsal 2026-10-08, finding 28: typing `D` and a long or odd file
//  name on a phone is slow and easy to get wrong. A file name in what a
//  station sends is a tap target that fills in the download command, with
//  the command word this operator uses for that station.
//

import XCTest
@testable import AXTerm

final class FileNameScannerTests: XCTestCase {

    private func names(_ text: String) -> [String] {
        FileNameScanner.names(in: text).map(\.name)
    }

    func testAnAXTermListingRow() {
        XCTAssertEqual(names("IMG_2820.jpg       25K   4:38  "), ["IMG_2820.jpg"])
    }

    func testALongNameOnItsOwnLine() {
        XCTAssertEqual(names("Photo-20261008-052732.jpg"), ["Photo-20261008-052732.jpg"])
    }

    /// The format other hosts use: upper case, size after the name.
    func testADOSStyleListing() {
        XCTAssertEqual(names("README.TXT     1234  KEPS2810.ZIP  20480"), ["README.TXT", "KEPS2810.ZIP"])
    }

    /// What the phone showed at 15:55Z: a long name with spaces on its own
    /// line and its size under it, then two ordinary rows.
    func testAnAXTermListingWithASpacedLongName() {
        let listing = """
        NAME              SIZE  TIME  ABOUT
        Barro tal vez v11.fcpxml
                           5K   <1m
        IMG_2820.jpg       24K   5m
        Photo-20261008-052732.jpg
                           12K   3m
        D <name> fetches one. U uploads to the sysop.
        """
        XCTAssertEqual(names(listing), ["Barro tal vez v11.fcpxml", "IMG_2820.jpg", "Photo-20261008-052732.jpg"])
    }

    func testALongNameWithCRLFLineEnds() {
        XCTAssertEqual(names("Barro tal vez v11.fcpxml\r\n                   5K   <1m\r\n"),
                       ["Barro tal vez v11.fcpxml"])
    }

    /// Without the size line under it, a sentence that ends in a file name
    /// links only the name.
    func testASentenceEndingInAFileNameLinksOnlyTheName() {
        XCTAssertEqual(names("Look in my notes.txt"), ["notes.txt"])
        XCTAssertEqual(names("Look in my notes.txt\nand tell me"), ["notes.txt"])
    }

    func testLongerExtensions() {
        XCTAssertEqual(names("edit.fcpxml  big.torrent"), ["edit.fcpxml", "big.torrent"])
    }

    func testTheRangeCoversTheNameOnly() {
        let text = "Try (notes.txt), then go."
        let hit = FileNameScanner.names(in: text).first
        XCTAssertEqual(hit.map { String(text[$0.range]) }, "notes.txt")
    }

    func testSizesVersionsAndNumbersAreNotFiles() {
        XCTAssertEqual(names("1.2MB at 12.5 B/s, version 2.0, 146K"), [])
    }

    func testAbbreviationsAndSentenceEndsAreNotFiles() {
        XCTAssertEqual(names("Done. See e.g. the list, i.e. W PARK."), [])
    }

    func testWebAddressesAndEmailAreNotFiles() {
        XCTAssertEqual(names("Mail me at op@example.com or see winlink.org and http://x.net/a.txt"), [])
    }

    func testTheHintLineHasNoFileInIt() {
        XCTAssertEqual(names("D <name> fetches one. U uploads to the sysop."), [])
    }
}

final class DownloadCommandTests: XCTestCase {

    func testTheVerbIsLearnedFromADownloadTheOperatorTyped() {
        XCTAssertEqual(DownloadCommand.verb(learnedFrom: "D IMG_2820.jpg"), "D")
        XCTAssertEqual(DownloadCommand.verb(learnedFrom: "  download keps.txt "), "DOWNLOAD")
    }

    func testOtherCommandsTeachNothing() {
        XCTAssertNil(DownloadCommand.verb(learnedFrom: "W PARK"))
        XCTAssertNil(DownloadCommand.verb(learnedFrom: "hello there.txt friend"))
        XCTAssertNil(DownloadCommand.verb(learnedFrom: "D"))
        XCTAssertNil(DownloadCommand.verb(learnedFrom: "73.txt"))
    }

    func testUploadsAndDeletesAreNotDownloads() {
        XCTAssertNil(DownloadCommand.verb(learnedFrom: "U photo.jpg"))
        XCTAssertNil(DownloadCommand.verb(learnedFrom: "K old.txt"))
    }

    func testTheLine() {
        XCTAssertEqual(DownloadCommand.line(verb: "D", name: "IMG_2820.jpg"), "D IMG_2820.jpg")
    }

    func testTheLinkCarriesTheNameBackUnchanged() {
        let name = "Photo-2026 (1)+x~.jpg"
        let url = ConsoleFileLink.url(for: name)
        XCTAssertNotNil(url)
        XCTAssertEqual(url.flatMap(ConsoleFileLink.name(from:)), name)
        XCTAssertNil(ConsoleFileLink.name(from: URL(string: "https://example.com/a.txt")!))
    }
}

@MainActor
final class DownloadCommandMemoryTests: XCTestCase {

    private func memory(_ name: String = #function) -> DownloadCommandMemory {
        DownloadCommandMemory(defaults: TestDefaults.make("DownloadCommandMemory-\(name)"))
    }

    func testAStationNobodyHasDownloadedFromGetsD() {
        XCTAssertEqual(memory().command(for: "IMG_2820.jpg", station: "K0EPI-4"), "D IMG_2820.jpg")
    }

    func testEachStationKeepsTheWordUsedWithIt() {
        let memory = memory()
        memory.learn(typed: "DOWNLOAD keps.txt", to: "k0abc-7")
        XCTAssertEqual(memory.command(for: "a.zip", station: "K0ABC-7"), "DOWNLOAD a.zip")
        XCTAssertEqual(memory.command(for: "a.zip", station: "K0EPI-4"), "D a.zip")
    }

    func testOtherLinesLeaveTheWordAlone() {
        let memory = memory()
        memory.learn(typed: "R keps.txt", to: "K0ABC-7")
        memory.learn(typed: "W FILES", to: "K0ABC-7")
        XCTAssertEqual(memory.command(for: "a.zip", station: "K0ABC-7"), "R a.zip")
    }

    func testTheWordIsRememberedAcrossLaunches() {
        let defaults = TestDefaults.make("DownloadCommandMemory-relaunch")
        DownloadCommandMemory(defaults: defaults).learn(typed: "GET keps.txt", to: "K0ABC-7")
        XCTAssertEqual(DownloadCommandMemory(defaults: defaults).command(for: "y.txt", station: "K0ABC-7"),
                       "GET y.txt")
    }
}
