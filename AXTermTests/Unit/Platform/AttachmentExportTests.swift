import UniformTypeIdentifiers
import XCTest
@testable import AXTerm

/// Getting received attachments out: the exporter's content types, the
/// actions each platform offers, and the temporary copies Quick Look,
/// Share and Open read.
final class AttachmentExportTests: XCTestCase {

    // MARK: - Exporter content types

    /// The iOS exporter is handed `exportContentType`; the document must
    /// declare it as writable, or saving a .jpg or .pdf on a device fails.
    func testEveryExportedTypeIsOneTheDocumentDeclares() {
        let writable = ExportableFileDocument.writableContentTypes
        for name in ["photo.jpg", "photo.JPEG", "scan.png", "IMG.heic", "report.pdf", "notes.txt",
                     "form.xml", "data.json", "archive.zip", "layer.geojson", "track.gpx", "zone.kml",
                     "body.b2fbody", "no-extension", "weird.qqqzzz", ""] {
            let type = ExportableFile(name: name, data: Data()).exportContentType
            XCTAssertTrue(writable.contains(type), "\(name) exports as \(type.identifier), which is not declared")
        }
    }

    func testKnownTypesExportAsThemselves() {
        let cases: [(String, UTType)] = [("a.jpg", .jpeg), ("a.png", .png), ("a.pdf", .pdf),
                                         ("a.heic", .heic), ("a.zip", .zip), ("a.txt", .plainText),
                                         ("a.xml", .xml), ("a.json", .json), ("a.gif", .gif)]
        for (name, type) in cases {
            XCTAssertEqual(ExportableFile(name: name, data: Data()).exportContentType, type, name)
        }
    }

    func testUnknownTypesExportAsPlainData() {
        XCTAssertEqual(ExportableFile(name: "weird.qqqzzz", data: Data()).exportContentType, .data)
        XCTAssertEqual(ExportableFile(name: "no-extension", data: Data()).exportContentType, .data)
    }

    /// Round trip: each declared type, written under its own extension,
    /// comes back as a declared type.
    func testDeclaredTypesRoundTripThroughTheirExtensions() {
        for type in ExportableFile.exportableTypes {
            guard let ext = type.preferredFilenameExtension else { continue }
            let exported = ExportableFile(name: "file.\(ext)", data: Data()).exportContentType
            XCTAssertTrue(ExportableFile.exportableTypes.contains(exported), "\(type.identifier) via .\(ext)")
            // Some types share an extension (.mp4 is audio and video); the
            // file comes back as whichever type the system gives that
            // extension, which is the one the Files app will show.
            XCTAssertEqual(exported, UTType(filenameExtension: ext),
                           "\(type.identifier) via .\(ext) came back as \(exported.identifier)")
        }
    }

    func testTheDocumentReadsWhatItWrites() {
        XCTAssertEqual(ExportableFileDocument.readableContentTypes, ExportableFileDocument.writableContentTypes)
        XCTAssertTrue(ExportableFileDocument.writableContentTypes.contains(.data), "the fallback is declared")
        XCTAssertEqual(Set(ExportableFile.exportableTypes).count, ExportableFile.exportableTypes.count, "no duplicates")
        XCTAssertFalse(ExportableFile.exportableTypes.contains { $0.isDynamic }, "no made-up identifiers")
    }

    // MARK: - Actions

    func testTheMacOffersOpenAndShowInFinder() {
        XCTAssertEqual(AttachmentActions.available(canAddToMap: false, platform: .mac),
                       [.quickLook, .open, .showInFinder, .save])
    }

    func testIOSOffersShare() {
        XCTAssertEqual(AttachmentActions.available(canAddToMap: false, platform: .iOS),
                       [.quickLook, .share, .save])
    }

    func testSpatialFilesAddAddToMapLast() {
        XCTAssertEqual(AttachmentActions.available(canAddToMap: true, platform: .iOS).last, .addToMap)
        XCTAssertEqual(AttachmentActions.available(canAddToMap: true, platform: .mac).last, .addToMap)
    }

    func testQuickLookComesFirstBecauseItIsWhatATapDoes() {
        XCTAssertEqual(AttachmentActions.available(canAddToMap: true, platform: .mac).first, .quickLook)
        XCTAssertEqual(AttachmentActions.available(canAddToMap: true, platform: .iOS).first, .quickLook)
    }

    func testEveryActionHasATitleAndASymbol() {
        for action in AttachmentAction.allCases {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.systemImage.isEmpty)
        }
    }

    func testHelpTextNamesTheGestureThatWorksHere() {
        XCTAssertEqual(AttachmentActions.secondaryClick(platform: .mac), "Right-click")
        XCTAssertEqual(AttachmentActions.secondaryClick(platform: .iOS), "Touch and hold")
    }

    func testHEICIsPreviewedInline() {
        XCTAssertTrue(AttachmentActions.isInlineImage(named: "IMG_0001.HEIC"))
        XCTAssertTrue(AttachmentActions.isInlineImage(named: "chart.png"))
        XCTAssertFalse(AttachmentActions.isInlineImage(named: "report.pdf"))
        XCTAssertFalse(AttachmentActions.isInlineImage(named: "form.xml"))
    }

    // MARK: - Temporary copies

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCopiesAreWrittenInOrderUnderTheirOwnNames() throws {
        let base = try tempRoot()
        let files = [ExportableFile(name: "a.txt", data: Data("a".utf8)),
                     ExportableFile(name: "b.jpg", data: Data("b".utf8))]
        let urls = try AttachmentPreviewFiles.write(files, messageID: "MID123", base: base)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["a.txt", "b.jpg"])
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, files.map(\.data))
        XCTAssertEqual(urls[0].deletingLastPathComponent(),
                       AttachmentPreviewFiles.directory(for: "MID123", base: base))
    }

    func testTwoAttachmentsWithOneNameGetTwoFiles() throws {
        let files = [ExportableFile(name: "x.txt", data: Data("1".utf8)),
                     ExportableFile(name: "x.txt", data: Data("2".utf8))]
        let urls = try AttachmentPreviewFiles.write(files, messageID: "M", base: try tempRoot())
        XCTAssertEqual(urls.map(\.lastPathComponent), ["x.txt", "x 2.txt"])
        XCTAssertEqual(try Data(contentsOf: urls[1]), Data("2".utf8))
    }

    func testANameFromTheSenderCannotEscapeTheFolder() throws {
        let base = try tempRoot()
        let urls = try AttachmentPreviewFiles.write([ExportableFile(name: "../../evil.txt", data: Data())],
                                                    messageID: "../M", base: base)
        XCTAssertTrue(IncomingDocumentRouter.isInside(urls[0], folder: base))
    }

    func testWritingAgainReusesTheCopies() throws {
        let base = try tempRoot()
        let files = [ExportableFile(name: "a.txt", data: Data("a".utf8))]
        let first = try AttachmentPreviewFiles.write(files, messageID: "M", base: base)
        let stamp = try first[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let second = try AttachmentPreviewFiles.write(files, messageID: "M", base: base)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try second[0].resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       stamp, "not rewritten")
    }

    func testPurgeRemovesOldMessagesOnly() throws {
        let base = try tempRoot()
        let old = try AttachmentPreviewFiles.write([ExportableFile(name: "a", data: Data())], messageID: "OLD", base: base)
        _ = try AttachmentPreviewFiles.write([ExportableFile(name: "b", data: Data())], messageID: "NEW", base: base)
        let oldFolder = old[0].deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)],
                                              ofItemAtPath: oldFolder.path)
        AttachmentPreviewFiles.purge(olderThan: 86_400, base: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: AttachmentPreviewFiles.directory(for: "NEW", base: base).path))
    }

    func testShowInFinderReusesAnIdenticalCopyAndNumbersADifferentOne() throws {
        let downloads = try tempRoot()
        let first = try AttachmentPreviewFiles.downloadsCopy(
            of: ExportableFile(name: "map.png", data: Data("one".utf8)), in: downloads)
        let again = try AttachmentPreviewFiles.downloadsCopy(
            of: ExportableFile(name: "map.png", data: Data("one".utf8)), in: downloads)
        let other = try AttachmentPreviewFiles.downloadsCopy(
            of: ExportableFile(name: "map.png", data: Data("two".utf8)), in: downloads)
        XCTAssertEqual(first, again, "the same bytes are not saved twice")
        XCTAssertEqual(other.lastPathComponent, "map 2.png", "different bytes are never saved over the first")
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, AttachmentPreviewFiles.folderName)
    }
}
