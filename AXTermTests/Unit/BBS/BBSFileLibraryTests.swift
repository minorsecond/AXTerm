import XCTest
import GRDB
@testable import AXTerm

/// Sharing a folder, end to end.
///
/// `BBSFileIndexTests` pins what the index does with a catalogue; this pins
/// how the catalogue comes to exist, which is the half the Files screen drives
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
                       "area names are normalised: callers type them blind on a radio link")
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
}
