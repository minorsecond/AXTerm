import XCTest
import GRDB
@testable import AXTerm

/// Sharing a folder, end to end.
///
/// `BBSFileIndexTests` pins what the index does with a catalog; this pins
/// how the catalog comes to exist, which is the half the Files screen drives
/// on both platforms. Everything here runs against a real folder on disk and a
/// real store, because the failures worth catching — a folder shared and then
/// listing nothing, a description that does not survive a rescan — are exactly
/// the ones a fake would not have.
@MainActor
final class BBSFileLibraryTests: XCTestCase {

    private var root: URL!
    private var store: SQLiteBBSMessageStore!

    /// Held by the test case, never by a local.
    ///
    /// `BBSFileLibrary` is `@MainActor`, and a Swift 6 actor-isolated class
    /// aborts in its deallocating deinit when the last release happens where
    /// the runtime cannot prove it is on that actor — which is what a local
    /// going out of scope at the end of a test body turns out to be. The
    /// crash has nothing to do with what is being tested, so nothing here
    /// creates one on the stack.
    private lazy var library: BBSFileLibrary = BBSFileLibrary(store: store)
    private var cappedLibrary: BBSFileLibrary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbs-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        store = SQLiteBBSMessageStore(dbQueue: queue)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, bytes: Int = 16, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func testSharingAFolderListsWhatIsInIt() throws {
        try write("netscript.txt")
        try write("roster.csv")

        library.addArea(name: "ops", about: "Nets", url: root)

        XCTAssertNil(library.lastScanError, "a folder that exists shares without complaint")
        XCTAssertEqual(library.index.areas.map(\.name), ["OPS"],
                       "area names are normalized: callers type them blind on a radio link")
        XCTAssertEqual(library.index.files(in: "OPS").map(\.name),
                       ["netscript.txt", "roster.csv"])
    }

    func testAnAreaWithNoBookmarkSaysSoRatherThanServingNothingQuietly() throws {
        try store.saveFileArea(BBSFileArea(name: "GHOST", about: "", bookmark: nil))
        library.rescan()

        XCTAssertTrue(library.index.files(in: "GHOST").isEmpty)
        XCTAssertEqual(library.lastScanError, "GHOST: folder is no longer reachable",
                       "an area that cannot be read must say so — a silently empty area "
                       + "reads as a folder the operator emptied")
    }

    func testScanningIsFlatAndSkipsWhatCallersMustNotSee() throws {
        try write("visible.txt")
        try write(".hidden.txt")
        try write("empty.txt", bytes: 0)

        let sub = root.appendingPathComponent("deeper")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try write("buried.txt", in: sub)

        let target = try write("target.txt", in: sub)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"), withDestinationURL: target)

        library.addArea(name: "OPS", about: "", url: root)

        XCTAssertEqual(library.index.files(in: "OPS").map(\.name), ["visible.txt"],
                       "one level deep, files only: a symlink is a way to serve something "
                       + "the operator never chose to share, a subfolder would need a path "
                       + "syntax the caller cannot see, and a zero-byte file is not a file")
    }

    func testAFileOverTheCapIsNotOffered() throws {
        cappedLibrary = BBSFileLibrary(store: store, maxFileBytes: 64)
        try write("small.txt", bytes: 32)
        try write("large.txt", bytes: 128)

        cappedLibrary.addArea(name: "OPS", about: "", url: root)

        XCTAssertEqual(cappedLibrary.index.files(in: "OPS").map(\.name), ["small.txt"],
                       "the cap is what stops a file area quoting a caller four hours")
    }

    func testADescriptionOutlivesARescanAndIsNotWrittenIntoTheFolder() throws {
        try write("roster.txt")
        library.addArea(name: "OPS", about: "", url: root)

        library.setDescription(area: "OPS", name: "roster.txt", about: "Duty roster, Q3")
        library.rescan()

        XCTAssertEqual(library.index.files(in: "OPS").first?.about, "Duty roster, Q3")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path),
                       ["roster.txt"],
                       "descriptions live in the database: the shared folder belongs to the "
                       + "operator and nothing here writes into it")
    }

    func testUnsharingAFolderLeavesTheFolderAlone() throws {
        try write("roster.txt")
        library.addArea(name: "OPS", about: "", url: root)

        library.removeArea(name: "OPS")

        XCTAssertTrue(library.index.areas.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            root.appendingPathComponent("roster.txt").path),
            "stopping sharing is a decision about this station, not about the operator's disk")
    }

    func testTheUploadInboxIsCountedButNeverServed() throws {
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try write("from-a-caller.txt", bytes: 100, in: inbox)

        library.setInbox(url: inbox)

        XCTAssertEqual(library.inboxName, "inbox")
        XCTAssertEqual(library.inboxCount, 1)
        XCTAssertEqual(library.inboxBytes, 100)
        XCTAssertTrue(library.index.files.isEmpty,
                      "an upload that was also shared would publish itself to every "
                      + "other caller the moment the transfer finished")
    }

    func testAnUploadNeverOverwritesWhatIsAlreadyThere() throws {
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        library.setInbox(url: inbox)

        XCTAssertEqual(library.saveUpload(name: "notes.txt", data: Data("one".utf8)),
                       "notes.txt")
        XCTAssertEqual(library.saveUpload(name: "notes.txt", data: Data("two".utf8)),
                       "notes-2.txt",
                       "a caller replacing a file is a way to change what the station serves")
    }

    // MARK: - Bookmarks that go stale or stop resolving

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testARenamedFolderIsFollowedAndItsBookmarkIsRefreshed() throws {
        let original = try folder("nets")
        try write("roster.txt", in: original)
        library.addArea(name: "OPS", about: "Nets", url: original)
        let before = try XCTUnwrap(store.fileAreas().first?.bookmark)

        let renamed = root.appendingPathComponent("nets-2026")
        try FileManager.default.moveItem(at: original, to: renamed)
        library.rescan()

        XCTAssertEqual(library.index.files(in: "OPS").map(\.name), ["roster.txt"],
                       "the bookmark follows the folder")
        XCTAssertTrue(library.unreachableAreas.isEmpty)
        let after = try XCTUnwrap(store.fileAreas().first?.bookmark)
        XCTAssertNotEqual(after, before, "a stale bookmark is replaced while it still resolves")
        let resolved = try XCTUnwrap(BBSFileLibrary.resolveBookmark(after))
        XCTAssertNil(resolved.refreshed, "the replacement is not stale")
        XCTAssertEqual(resolved.url.standardizedFileURL.lastPathComponent, "nets-2026")
        XCTAssertEqual(try store.fileAreas().first?.about, "Nets", "refreshing keeps the description")
    }

    func testAFolderThatIsGoneIsListedAsUnreachableAndCanBeChosenAgain() throws {
        let original = try folder("nets")
        try write("roster.txt", in: original)
        library.addArea(name: "OPS", about: "Nets", url: original)
        library.setDescription(area: "OPS", name: "roster.txt", about: "Duty roster")

        try FileManager.default.removeItem(at: original)
        library.rescan()

        XCTAssertEqual(library.unreachableAreas, ["OPS"],
                       "named, so the Files screen can offer to choose it again")
        XCTAssertEqual(library.index.areas.map(\.name), ["OPS"], "still listed, not forgotten")
        XCTAssertTrue(library.lastScanError?.contains("OPS: folder is no longer reachable") == true)

        let replacement = try folder("nets-restored")
        try write("roster.txt", in: replacement)
        library.relocateArea(name: "ops", url: replacement)

        XCTAssertTrue(library.unreachableAreas.isEmpty)
        XCTAssertNil(library.lastScanError)
        XCTAssertEqual(library.index.areas.first?.about, "Nets", "the area keeps its description")
        XCTAssertEqual(library.index.files(in: "OPS").first?.about, "Duty roster",
                       "and so do its files")
    }

    func testAnInboxThatIsGoneSaysSoAndCanBeChosenAgain() throws {
        let inbox = try folder("inbox")
        library.setInbox(url: inbox)
        XCTAssertTrue(library.hasInbox)
        XCTAssertFalse(library.inboxUnreachable)

        try FileManager.default.removeItem(at: inbox)
        library.refreshInbox()
        XCTAssertFalse(library.hasInbox, "uploads are refused, not written somewhere unexpected")
        XCTAssertTrue(library.inboxUnreachable,
                      "a chosen folder that went missing reads differently from none chosen")
        XCTAssertNil(library.saveUpload(name: "x.txt", data: Data("x".utf8)))

        library.setInbox(url: try folder("inbox-new"))
        XCTAssertTrue(library.hasInbox)
        XCTAssertFalse(library.inboxUnreachable)
    }

    // MARK: - Adding files from inside the app

    func testAddingFilesCopiesThemIntoTheAreaAndLeavesTheOriginals() throws {
        let area = try folder("ops")
        library.addArea(name: "OPS", about: "", url: area)
        let elsewhere = try folder("desktop")
        let one = try write("netscript.txt", bytes: 40, in: elsewhere)
        let two = try write("map.png", bytes: 900, in: elsewhere)

        let outcomes = library.addFiles([one, two], to: "ops")

        XCTAssertEqual(outcomes, [.added(name: "netscript.txt"), .added(name: "map.png")])
        XCTAssertEqual(library.index.files(in: "OPS").map(\.name), ["map.png", "netscript.txt"],
                       "offered to callers at once, without a manual rescan")
        XCTAssertTrue(FileManager.default.fileExists(atPath: one.path), "copied, not moved")
        XCTAssertEqual(try Data(contentsOf: area.appendingPathComponent("map.png")).count, 900)
    }

    func testAddingAFileNeverReplacesOneAlreadyShared() throws {
        let area = try folder("ops")
        try write("roster.txt", bytes: 10, in: area)
        library.addArea(name: "OPS", about: "", url: area)
        let incoming = try write("ROSTER.TXT", bytes: 20, in: try folder("desktop"))

        XCTAssertEqual(library.addFiles([incoming], to: "OPS"),
                       [.renamed(from: "ROSTER.TXT", to: "ROSTER-2.TXT")])
        XCTAssertEqual(try Data(contentsOf: area.appendingPathComponent("roster.txt")).count, 10,
                       "a caller who fetched roster.txt by name still gets the same file")
    }

    func testAddingRefusesWhatTheScanWouldNeverOffer() throws {
        cappedLibrary = BBSFileLibrary(store: store, maxFileBytes: 64)
        let area = try folder("ops")
        cappedLibrary.addArea(name: "OPS", about: "", url: area)
        let desktop = try folder("desktop")
        let empty = try write("empty.txt", bytes: 0, in: desktop)
        let large = try write("large.bin", bytes: 128, in: desktop)
        let subfolder = try folder("desktop/sub")

        let outcomes = cappedLibrary.addFiles([empty, large, subfolder], to: "OPS")

        XCTAssertEqual(outcomes, [
            .refused(name: "empty.txt", reason: "it is empty"),
            .refused(name: "large.bin", reason: "it is over the 64B limit, so callers would never see it"),
            .refused(name: "sub", reason: "folders are not shared, only the files in them")
        ])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: area.path), [],
                       "nothing was written")
    }

    func testAddingToAnAreaThatDoesNotExistOrCannotBeReachedIsRefused() throws {
        let area = try folder("ops")
        library.addArea(name: "OPS", about: "", url: area)
        let file = try write("a.txt", in: try folder("desktop"))

        XCTAssertEqual(library.addFiles([file], to: "NOPE"),
                       [.refused(name: "a.txt", reason: "the NOPE folder cannot be reached")])
        try FileManager.default.removeItem(at: area)
        XCTAssertEqual(library.addFiles([file], to: "OPS"),
                       [.refused(name: "a.txt", reason: "the OPS folder cannot be reached")])
    }

    func testANameThatIsAPathIsRefusedAndNothingLandsOutsideTheArea() throws {
        let area = try folder("ops")
        library.addArea(name: "OPS", about: "", url: area)
        let data = Data("x".utf8)

        for name in ["../escape.txt", "..", ".", ".hidden", "a/b.txt", "c\\d.txt",
                     "e:f.txt", "bell\u{07}.txt", "   ", ""] {
            XCTAssertEqual(library.addFile(named: name, data: data, to: "OPS"),
                           .refused(name: name, reason: "that name cannot be used for a shared file"),
                           "refused: \(name.debugDescription)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: area.path), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("escape.txt").path))

        XCTAssertEqual(library.addFile(named: "Net Script (v2).txt", data: data, to: "OPS"),
                       .added(name: "Net Script (v2).txt"),
                       "the operator's own name is kept when it is a plain leaf")
    }
}
