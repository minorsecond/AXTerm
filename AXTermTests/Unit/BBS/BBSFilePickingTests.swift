import XCTest
import GRDB
import UniformTypeIdentifiers
@testable import AXTerm

/// The Files screens' one importer, what each pick does, and what the
/// operator is told afterwards.
///
/// The Mac pane used to hang two `.fileImporter` modifiers on one view, and
/// SwiftUI presents only one of them, so a button did nothing. Both
/// platforms now route every pick through `BBSFilePickPurpose` and
/// `BBSFilePick`, which is what these pin, against a real folder and store.
@MainActor
final class BBSFilePickingTests: XCTestCase {

    private var root: URL!
    private var store: SQLiteBBSMessageStore!
    private lazy var library = BBSFileLibrary(store: store)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbs-picking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        store = SQLiteBBSMessageStore(dbQueue: queue)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The purpose decides what the importer accepts

    func testFolderPurposesPickOneFolderAndAddingFilesPicksMany() {
        for purpose in [BBSFilePickPurpose.shareFolder, .uploadInbox, .relocate(area: "OPS")] {
            XCTAssertEqual(purpose.contentTypes, [.folder], "\(purpose)")
            XCTAssertFalse(purpose.allowsMultipleSelection, "\(purpose)")
        }
        XCTAssertEqual(BBSFilePickPurpose.addFiles(area: "OPS").contentTypes, [.item])
        XCTAssertTrue(BBSFilePickPurpose.addFiles(area: "OPS").allowsMultipleSelection)
    }

    func testEveryPurposeHasItsOwnIdentity() {
        let ids = [BBSFilePickPurpose.shareFolder, .uploadInbox,
                   .relocate(area: "OPS"), .relocate(area: "WX"),
                   .addFiles(area: "OPS"), .addFiles(area: "WX")].map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "one presenter, told apart by value, never by which modifier fired")
    }

    // MARK: - Each purpose does its own job

    func testSharingAFolderAsksForTheAreaNameFirst() throws {
        let nets = try folder("nets")
        XCTAssertEqual(BBSFilePick.apply(.shareFolder, urls: [nets], library: library),
                       .nameNewArea(nets))
        XCTAssertTrue(library.index.areas.isEmpty, "nothing is shared until it is named")
    }

    func testChoosingTheInboxSetsTheInboxAndSharesNothing() throws {
        let inbox = try folder("inbox")
        XCTAssertEqual(BBSFilePick.apply(.uploadInbox, urls: [inbox], library: library),
                       .finished(message: nil))
        XCTAssertEqual(library.inboxName, "inbox")
        XCTAssertTrue(library.index.areas.isEmpty,
                      "the inbox picker must never share the folder it was given")
    }

    func testChoosingAMissingAreasFolderAgainReconnectsIt() throws {
        let original = try folder("nets")
        library.addArea(name: "OPS", about: "Nets", url: original)
        try FileManager.default.removeItem(at: original)
        library.rescan()
        XCTAssertEqual(library.unreachableAreas, ["OPS"])

        let restored = try folder("restored")
        try Data("x".utf8).write(to: restored.appendingPathComponent("roster.txt"))
        XCTAssertEqual(BBSFilePick.apply(.relocate(area: "OPS"), urls: [restored], library: library),
                       .finished(message: nil))
        XCTAssertTrue(library.unreachableAreas.isEmpty)
        XCTAssertEqual(library.index.files(in: "OPS").map(\.name), ["roster.txt"])
    }

    func testAddingFilesCopiesThemAndSaysWhatHappened() throws {
        let area = try folder("ops")
        try Data("old".utf8).write(to: area.appendingPathComponent("roster.txt"))
        library.addArea(name: "OPS", about: "", url: area)
        let desktop = try folder("desktop")
        let fresh = desktop.appendingPathComponent("netscript.txt")
        let clash = desktop.appendingPathComponent("roster.txt")
        let empty = desktop.appendingPathComponent("empty.txt")
        try Data("net".utf8).write(to: fresh)
        try Data("new".utf8).write(to: clash)
        try Data().write(to: empty)

        let result = BBSFilePick.apply(.addFiles(area: "OPS"), urls: [fresh, clash, empty],
                                       library: library)

        XCTAssertEqual(result, .finished(message: """
            Added 2 files to OPS.
            roster.txt was added as roster-2.txt, because OPS already has a file called roster.txt.
            empty.txt was not added: it is empty.
            """))
        XCTAssertEqual(library.index.files(in: "OPS").map(\.name),
                       ["netscript.txt", "roster-2.txt", "roster.txt"])
    }

    // MARK: - Summaries

    func testASummaryForOneFileIsSingular() {
        XCTAssertEqual(BBSAddFilesSummary.message(for: [.added(name: "a.txt")], area: "OPS"),
                       "Added 1 file to OPS.")
    }

    func testASummaryWhereNothingWentInSaysOnlyWhy() {
        XCTAssertEqual(
            BBSAddFilesSummary.message(for: [.refused(name: "x", reason: "it is empty")], area: "OPS"),
            "x was not added: it is empty.")
    }

    func testNoFilesMeansNoMessage() {
        XCTAssertNil(BBSAddFilesSummary.message(for: [], area: "OPS"))
    }
}

/// What the live call panel shows while a file is on its way.
final class BBSTransferRowModelTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func status(_ direction: BBSService.TransferStatus.Direction,
                        name: String? = "roster.zip", done: Int = 0,
                        total: Int = 0) -> BBSService.TransferStatus {
        BBSService.TransferStatus(direction: direction, caller: "W0ARP-1", fileName: name,
                                  protocolName: "YAPP", bytesDone: done, totalBytes: total,
                                  startedAt: start)
    }

    func testADownloadSaysWhoWhatHowFarAndHowLong() {
        let model = BBSTransferRowModel.make(status(.download, done: 12_288, total: 40_960),
                                             now: start.addingTimeInterval(65))
        XCTAssertEqual(model.title, "Sending roster.zip to W0ARP-1")
        XCTAssertEqual(model.detail, "12K of 40K · 30% · YAPP · 1:05")
        XCTAssertEqual(model.fraction ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertEqual(model.systemImage, "arrow.down.doc")
    }

    func testAnUploadBeforeItsHeaderHasNoNameAndNoBar() {
        let model = BBSTransferRowModel.make(status(.upload, name: nil), now: start)
        XCTAssertEqual(model.title, "Waiting for W0ARP-1's upload to begin")
        XCTAssertNil(model.fraction, "an indeterminate bar, not one stuck at zero")
        XCTAssertEqual(model.detail, "YAPP · 0:00")
        XCTAssertEqual(model.systemImage, "arrow.up.doc")
    }

    func testAnUploadAfterItsHeaderIsNamedAndMeasured() {
        let model = BBSTransferRowModel.make(status(.upload, name: "log.txt", done: 512, total: 1024),
                                             now: start.addingTimeInterval(3))
        XCTAssertEqual(model.title, "Receiving log.txt from W0ARP-1")
        XCTAssertEqual(model.detail, "512B of 1K · 50% · YAPP · 0:03")
    }

    func testProgressNeverReadsPastTheEnd() {
        let model = BBSTransferRowModel.make(status(.download, done: 5000, total: 4000), now: start)
        XCTAssertEqual(model.fraction, 1)
        XCTAssertTrue(model.detail.hasPrefix("4K of 4K · 100%"), model.detail)
    }
}
