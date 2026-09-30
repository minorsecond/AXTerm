//
//  ReceivedFileStoreTests.swift
//  AXTermTests
//
//  Where a received file goes on each platform, what it is called, and that
//  nothing already there is ever overwritten.
//

import XCTest
@testable import AXTerm

final class ReceivedFileStoreTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReceivedFileStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Folder per platform

    private let downloads = URL(fileURLWithPath: "/Users/op/Downloads", isDirectory: true)
    private let documents = URL(fileURLWithPath: "/Users/op/Documents", isDirectory: true)

    func testTheMacSavesInDownloads() {
        let url = ReceivedFileStore.folder(for: .macOS, downloads: downloads, documents: documents)
        XCTAssertEqual(url?.path, "/Users/op/Downloads/AXTerm Transfers")
    }

    func testTheMacFallsBackToDocumentsWithoutDownloads() {
        let url = ReceivedFileStore.folder(for: .macOS, downloads: nil, documents: documents)
        XCTAssertEqual(url?.path, "/Users/op/Documents/AXTerm Transfers")
    }

    /// iOS hands out a Downloads folder inside the container that the Files
    /// app cannot see. Documents is the one it shows.
    func testIOSSavesInDocumentsEvenWhenADownloadsFolderExists() {
        let url = ReceivedFileStore.folder(for: .iOS, downloads: downloads, documents: documents)
        XCTAssertEqual(url?.path, "/Users/op/Documents/AXTerm Transfers")
    }

    func testIOSWithoutDocumentsHasNowhereToSave() {
        XCTAssertNil(ReceivedFileStore.folder(for: .iOS, downloads: downloads, documents: nil))
    }

    func testTheFolderNameIsWhatTheUINames() {
        XCTAssertEqual(ReceivedFileStore.folderName, "AXTerm Transfers")
    }

    func testThisDeviceGetsItsPlatformsFolder() {
        let url = ReceivedFileStore.defaultFolder()
        XCTAssertEqual(url?.lastPathComponent, "AXTerm Transfers")
        #if os(macOS)
        XCTAssertEqual(ReceivedFileStore.Platform.current, .macOS)
        #endif
    }

    // MARK: - Names from another station

    func testPathsCannotClimbOutOfTheFolder() {
        XCTAssertEqual(ReceivedFileStore.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(ReceivedFileStore.sanitize("..\\..\\WINDOWS\\WIN.INI"), "WIN.INI")
        XCTAssertEqual(ReceivedFileStore.sanitize("C:\\FILES\\GAME.ZIP"), "GAME.ZIP")
        XCTAssertEqual(ReceivedFileStore.sanitize("/absolute/path.txt"), "path.txt")
        XCTAssertEqual(ReceivedFileStore.sanitize("..") , "received-file")
        XCTAssertEqual(ReceivedFileStore.sanitize("."), "received-file")
        XCTAssertEqual(ReceivedFileStore.sanitize("dir/"), "received-file")
    }

    func testNothingArrivesHidden() {
        XCTAssertEqual(ReceivedFileStore.sanitize(".bashrc"), "bashrc")
        XCTAssertEqual(ReceivedFileStore.sanitize("...secret"), "secret")
    }

    func testControlCharactersAreReplaced() {
        XCTAssertEqual(ReceivedFileStore.sanitize("a\u{0}b\u{7}c.txt"), "a_b_c.txt")
        XCTAssertEqual(ReceivedFileStore.sanitize("x\u{7F}.bin"), "x_.bin")
    }

    func testBlankNamesGetAPlaceholder() {
        XCTAssertEqual(ReceivedFileStore.sanitize(""), "received-file")
        XCTAssertEqual(ReceivedFileStore.sanitize("   \n\t  "), "received-file")
    }

    func testLongNamesAreCutButKeepTheirExtension() {
        let name = String(repeating: "a", count: 500) + ".jpeg"
        let cleaned = ReceivedFileStore.sanitize(name)
        XCTAssertEqual(cleaned.count, ReceivedFileStore.maxNameLength)
        XCTAssertTrue(cleaned.hasSuffix(".jpeg"))
    }

    func testOrdinaryNamesPassThrough() {
        XCTAssertEqual(ReceivedFileStore.sanitize("KEPS.TXT"), "KEPS.TXT")
        XCTAssertEqual(ReceivedFileStore.sanitize("map layer 2.geojson"), "map layer 2.geojson")
    }

    // MARK: - Never overwrite

    func testCollisionsCountUpFromTwo() {
        var taken: Set<String> = ["/f/report.txt", "/f/report 2.txt"]
        let base = URL(fileURLWithPath: "/f", isDirectory: true)
        let pick = { ReceivedFileStore.uniqueURL(for: "report.txt", in: base) { taken.contains($0.path) } }
        XCTAssertEqual(pick().lastPathComponent, "report 3.txt")
        taken.insert("/f/report 3.txt")
        XCTAssertEqual(pick().lastPathComponent, "report 4.txt")
    }

    func testCollisionsWithoutAnExtension() {
        let base = URL(fileURLWithPath: "/f", isDirectory: true)
        let url = ReceivedFileStore.uniqueURL(for: "README", in: base) { $0.lastPathComponent == "README" }
        XCTAssertEqual(url.lastPathComponent, "README 2")
    }

    func testSavingTheSameNameThreeTimesKeepsAllThree() throws {
        let first = try ReceivedFileStore.save(Data("one".utf8), suggestedName: "same.txt", in: folder)
        let second = try ReceivedFileStore.save(Data("two".utf8), suggestedName: "same.txt", in: folder)
        let third = try ReceivedFileStore.save(Data("three".utf8), suggestedName: "same.txt", in: folder)
        XCTAssertEqual([first, second, third].map(\.lastPathComponent), ["same.txt", "same 2.txt", "same 3.txt"])
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8), "the first file is untouched")
        XCTAssertEqual(try Data(contentsOf: third), Data("three".utf8))
    }

    func testSavingAHostileNameStaysInTheFolder() throws {
        let url = try ReceivedFileStore.save(Data([1]), suggestedName: "../../escape.bin", in: folder)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(url.lastPathComponent, "escape.bin")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("escape.bin").path))
    }

    func testSavingCreatesTheFolder() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        _ = try ReceivedFileStore.save(Data(), suggestedName: "empty.bin", in: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("empty.bin").path))
    }

    func testSavingWithNoFolderSaysSo() {
        XCTAssertThrowsError(try ReceivedFileStore.save(Data(), suggestedName: "x", in: nil)) { error in
            XCTAssertEqual(error as? ReceivedFileStore.SaveError, .noFolder)
        }
    }
}

/// The folder made ready at launch, and the note that names it.
final class ReceivedFileFolderPrepTests: XCTestCase {
    func testTheMacsDownloadsIsLeftAloneUntilAFileArrives() {
        XCTAssertNil(ReceivedFileStore.prepareFolder(platform: .macOS))
    }

    func testTheNoteNamesTheFolderInEachDevicesWords() {
        XCTAssertTrue(TransferCopy.receivedFilesNote(for: .mac).contains("Downloads › AXTerm Transfers"))
        for device in [TransferDevice.iPhone, .iPad] {
            let note = TransferCopy.receivedFilesNote(for: device)
            XCTAssertTrue(note.contains("Files app"), note)
            XCTAssertTrue(note.contains(ReceivedFileStore.folderName), note)
        }
    }
}
