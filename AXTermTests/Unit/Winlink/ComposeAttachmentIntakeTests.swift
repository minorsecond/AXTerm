import UniformTypeIdentifiers
import XCTest
@testable import AXTerm

/// Drag and drop, paste and the photo library into compose: which
/// representation is read, and what the result is called.
final class ComposeAttachmentIntakeTests: XCTestCase {

    // MARK: - Route

    func testAFileURLWinsOverEverythingElse() {
        let types = [UTType.png.identifier, UTType.fileURL.identifier, UTType.plainText.identifier]
        XCTAssertEqual(ComposeAttachmentIntake.route(for: types, hasSuggestedName: false), .fileURL)
    }

    func testTheFirstDataTypeIsUsedInTheSourcesOwnOrder() {
        let types = [UTType.heic.identifier, UTType.jpeg.identifier]
        XCTAssertEqual(ComposeAttachmentIntake.route(for: types, hasSuggestedName: false),
                       .file(typeIdentifier: UTType.heic.identifier))
    }

    func testDraggedTextIsNotAnAttachment() {
        let types = [UTType.utf8PlainText.identifier, UTType.plainText.identifier]
        XCTAssertEqual(ComposeAttachmentIntake.route(for: types, hasSuggestedName: false), .unsupported)
    }

    func testATextFileWithANameIsAnAttachment() {
        XCTAssertEqual(ComposeAttachmentIntake.route(for: [UTType.plainText.identifier], hasSuggestedName: true),
                       .file(typeIdentifier: UTType.plainText.identifier))
    }

    func testAWebLinkWithoutANameIsNotAnAttachment() {
        XCTAssertEqual(ComposeAttachmentIntake.route(for: [UTType.url.identifier], hasSuggestedName: false),
                       .unsupported)
    }

    func testTextIsSkippedInFavorOfALaterPicture() {
        let types = [UTType.plainText.identifier, UTType.png.identifier]
        XCTAssertEqual(ComposeAttachmentIntake.route(for: types, hasSuggestedName: false),
                       .file(typeIdentifier: UTType.png.identifier))
    }

    func testNothingOfferedIsUnsupported() {
        XCTAssertEqual(ComposeAttachmentIntake.route(for: [], hasSuggestedName: true), .unsupported)
        XCTAssertEqual(ComposeAttachmentIntake.route(for: ["com.example.not-a-type"], hasSuggestedName: true),
                       .unsupported)
    }

    // MARK: - Names

    func testASuggestedNameGetsTheTypesExtension() {
        XCTAssertEqual(ComposeAttachmentIntake.name(suggested: "IMG_0042", contentType: .heic, fallbackStem: "x"),
                       "IMG_0042.heic")
    }

    func testASuggestedNameWithAnExtensionIsKept() {
        XCTAssertEqual(ComposeAttachmentIntake.name(suggested: "report.pdf", contentType: .pdf, fallbackStem: "x"),
                       "report.pdf")
    }

    func testNoNameFallsBack() {
        XCTAssertEqual(ComposeAttachmentIntake.name(suggested: nil, contentType: .png, fallbackStem: "Pasted"),
                       "Pasted.png")
        XCTAssertEqual(ComposeAttachmentIntake.name(suggested: "   ", contentType: .png, fallbackStem: "Pasted"),
                       "Pasted.png")
    }

    func testPhotosAreNumbered() {
        XCTAssertEqual(ComposeAttachmentIntake.photoName(index: 1, contentType: .heic), "Photo 1.heic")
        XCTAssertEqual(ComposeAttachmentIntake.photoName(index: 3, contentType: .jpeg), "Photo 3.jpeg")
        XCTAssertEqual(ComposeAttachmentIntake.photoName(index: 2, contentType: nil), "Photo 2.jpg")
    }

    func testANameAlreadyTakenGetsANumber() {
        XCTAssertEqual(ComposeAttachmentIntake.uniqueName("a.jpg", existing: []), "a.jpg")
        XCTAssertEqual(ComposeAttachmentIntake.uniqueName("a.jpg", existing: ["a.jpg"]), "a 2.jpg")
        XCTAssertEqual(ComposeAttachmentIntake.uniqueName("a.jpg", existing: ["a.jpg", "a 2.jpg"]), "a 3.jpg")
        XCTAssertEqual(ComposeAttachmentIntake.uniqueName("A.JPG", existing: ["a.jpg"]), "A 2.JPG",
                       "case-insensitive, as the recipient's file system probably is")
        XCTAssertEqual(ComposeAttachmentIntake.uniqueName("notes", existing: ["notes"]), "notes 2")
    }

    func testANumberedNameCountsOnRatherThanNesting() {
        XCTAssertEqual(ComposeAttachmentIntake.uniqueName("Photo 1.jpg", existing: ["Photo 1.jpg"]), "Photo 2.jpg")
    }

    func testSeparatorsAreTakenOutOfNames() {
        XCTAssertEqual(ComposeAttachmentIntake.sanitized("../etc/passwd"), "..-etc-passwd")
        XCTAssertEqual(ComposeAttachmentIntake.sanitized("a:b\\c"), "a-b-c")
        XCTAssertEqual(ComposeAttachmentIntake.sanitized("   "), "Attachment")
    }

    // MARK: - Reading

    func testReadingAMissingFileReportsNothingRatherThanEmptyBytes() {
        XCTAssertNil(ComposeAttachmentIntake.read(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).txt")))
    }

    func testDroppedFileURLsAreRead() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString).txt")
        try Data("dropped".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = NSItemProvider(object: url as NSURL)
        let result = await ComposeAttachmentIntake.load([provider])
        XCTAssertEqual(result.files, [ComposeIncomingFile(name: url.lastPathComponent, data: Data("dropped".utf8))])
        XCTAssertEqual(result.failures, [])
    }

    func testAPastedPictureWithNoNameIsNamedForItsType() async throws {
        let png = try XCTUnwrap(SyntheticPhoto.data(width: 40, height: 30, type: .png))
        let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        let result = await ComposeAttachmentIntake.load([provider])
        XCTAssertEqual(result.files.map(\.name), ["Pasted.png"])
        XCTAssertEqual(result.files.first?.data, png)
    }

    func testASecondUnnamedItemIsNumbered() async throws {
        let png = try XCTUnwrap(SyntheticPhoto.data(width: 40, height: 30, type: .png))
        let providers = [
            NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier),
            NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier),
        ]
        let result = await ComposeAttachmentIntake.load(providers)
        XCTAssertEqual(result.files.map(\.name), ["Pasted.png", "Pasted 2.png"])
    }

    func testANamedItemKeepsItsName() async throws {
        let provider = NSItemProvider(item: Data("73".utf8) as NSData, typeIdentifier: UTType.plainText.identifier)
        provider.suggestedName = "log"
        let result = await ComposeAttachmentIntake.load([provider])
        XCTAssertEqual(result.files.map(\.name), ["log.txt"])
    }

    func testDraggedTextIsReportedNotAttached() async {
        let provider = NSItemProvider(item: "hello" as NSString, typeIdentifier: UTType.utf8PlainText.identifier)
        let result = await ComposeAttachmentIntake.load([provider])
        XCTAssertEqual(result.files, [])
        XCTAssertEqual(result.failures.count, 1, "something the operator dropped is never silently lost")
    }
}
