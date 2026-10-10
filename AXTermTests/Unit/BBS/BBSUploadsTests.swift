import XCTest
import GRDB
@testable import AXTerm

/// The uploads a mailbox has taken, as the BBS window lists them.
///
/// At the home retest (2026-10-10) the BBS window showed only "docs · 2
/// files" for the inbox, and finding and opening the iPad's photo took
/// Finder. The library now lists each upload with its size, when it arrived
/// and who sent it, and can move one into an area or put it in the Trash.
@MainActor
final class BBSUploadsTests: XCTestCase {

    private var root: URL!
    private var inbox: URL!
    private var park: URL!
    private var store: SQLiteBBSMessageStore!
    private var trashed: [String] = []

    /// Held by the test case, never by a local (see `BBSFileLibraryTests`).
    private lazy var library: BBSFileLibrary = makeLibrary()
    private var relaunched: BBSFileLibrary!

    private func makeLibrary() -> BBSFileLibrary {
        let library = BBSFileLibrary(store: store)
        // Nothing from a test goes in the operator's real Trash.
        library.trash = { [unowned self] url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        return library
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbs-uploads-\(UUID().uuidString)")
        inbox = root.appendingPathComponent("docs")
        park = root.appendingPathComponent("park")
        for folder in [inbox!, park!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        store = SQLiteBBSMessageStore(dbQueue: queue)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let arrived = Date(timeIntervalSince1970: 1_791_660_000)

    private func exists(_ name: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    func testAnUploadIsListedWithWhoSentItAndWhen() {
        library.setInbox(url: inbox)
        XCTAssertEqual(library.saveUpload(name: "Photo.jpg", data: Data(count: 300), from: "K0EPI-3", at: arrived),
                       "Photo.jpg")
        XCTAssertEqual(library.uploads,
                       [BBSUpload(name: "Photo.jpg", byteCount: 300, receivedAt: arrived, from: "K0EPI-3")])
    }

    /// A file the operator put in the folder themselves has no sender; it
    /// shows with the file's own date.
    func testAFilePutInTheInboxByHandHasNoSender() throws {
        try Data(count: 10).write(to: inbox.appendingPathComponent("notes.txt"))
        library.setInbox(url: inbox)
        let upload = try XCTUnwrap(library.uploads.first)
        XCTAssertEqual(upload.name, "notes.txt")
        XCTAssertEqual(upload.byteCount, 10)
        XCTAssertNil(upload.from)
        XCTAssertLessThan(abs(upload.receivedAt.timeIntervalSinceNow), 60)
    }

    func testTheNewestUploadComesFirst() {
        library.setInbox(url: inbox)
        library.saveUpload(name: "a.bin", data: Data(count: 1), from: "K0EPI-3", at: arrived)
        library.saveUpload(name: "b.bin", data: Data(count: 1), from: "W0ARP-1", at: arrived.addingTimeInterval(60))
        XCTAssertEqual(library.uploads.map(\.name), ["b.bin", "a.bin"])
    }

    func testWhoSentItSurvivesARelaunch() {
        library.setInbox(url: inbox)
        library.saveUpload(name: "Photo.jpg", data: Data(count: 300), from: "K0EPI-3", at: arrived)
        relaunched = makeLibrary()
        relaunched.refreshInbox()
        XCTAssertEqual(relaunched.uploads.first?.from, "K0EPI-3")
        XCTAssertEqual(relaunched.uploads.first?.receivedAt, arrived)
    }

    /// Moving one into an area is how it gets shared: it leaves the inbox
    /// and callers can list it.
    func testMovingAnUploadIntoAnAreaSharesIt() {
        library.addArea(name: "PARK", about: "", url: park)
        library.setInbox(url: inbox)
        library.saveUpload(name: "Photo.jpg", data: Data(count: 300), from: "K0EPI-3", at: arrived)

        XCTAssertEqual(library.moveUpload(named: "Photo.jpg", toArea: "PARK"), .added(name: "Photo.jpg"))
        XCTAssertTrue(library.uploads.isEmpty)
        XCTAssertFalse(exists("Photo.jpg", in: inbox))
        XCTAssertTrue(exists("Photo.jpg", in: park))
        XCTAssertEqual(library.index.files(in: "PARK").map(\.name), ["Photo.jpg"])
    }

    func testMovingNeverReplacesAFileInTheArea() throws {
        try Data("the old one".utf8).write(to: park.appendingPathComponent("Photo.jpg"))
        library.addArea(name: "PARK", about: "", url: park)
        library.setInbox(url: inbox)
        library.saveUpload(name: "Photo.jpg", data: Data(count: 300), from: "K0EPI-3", at: arrived)

        XCTAssertEqual(library.moveUpload(named: "Photo.jpg", toArea: "PARK"),
                       .renamed(from: "Photo.jpg", to: "Photo-2.jpg"))
        XCTAssertEqual(try Data(contentsOf: park.appendingPathComponent("Photo.jpg")), Data("the old one".utf8))
        XCTAssertFalse(exists("Photo.jpg", in: inbox))
    }

    /// Delete puts it in the Trash, and forgets who sent it, so a later file
    /// of the same name is not credited to them.
    func testDeletingAnUploadPutsItInTheTrash() throws {
        library.setInbox(url: inbox)
        library.saveUpload(name: "Photo.jpg", data: Data(count: 300), from: "K0EPI-3", at: arrived)

        try library.trashUpload(named: "Photo.jpg")
        XCTAssertEqual(trashed, ["Photo.jpg"])
        XCTAssertTrue(library.uploads.isEmpty)

        try Data(count: 5).write(to: inbox.appendingPathComponent("Photo.jpg"))
        library.refreshInbox()
        XCTAssertNil(library.uploads.first?.from)
    }

    /// Only a file in the inbox can be moved or deleted from this list.
    func testANameOutsideTheInboxIsRefused() throws {
        library.setInbox(url: inbox)
        try Data(count: 5).write(to: root.appendingPathComponent("secret.txt"))
        XCTAssertThrowsError(try library.trashUpload(named: "../secret.txt"))
        XCTAssertTrue(exists("secret.txt", in: root))
        XCTAssertTrue(trashed.isEmpty)
    }

    /// What the window says after Move to Area.
    func testTheMoveIsReported() {
        XCTAssertEqual(BBSUploadMoveReport.message([.added(name: "a.jpg")], area: "PARK"),
                       "Moved a.jpg to PARK. Callers can list it now.")
        XCTAssertEqual(BBSUploadMoveReport.message([.added(name: "a.jpg"), .added(name: "b.jpg")], area: "PARK"),
                       "Moved 2 files to PARK. Callers can list them now.")
        XCTAssertEqual(BBSUploadMoveReport.message([.renamed(from: "Photo.jpg", to: "Photo-2.jpg")], area: "PARK"),
                       "Moved Photo.jpg to PARK as Photo-2.jpg, because PARK already has a file called Photo.jpg.")
        XCTAssertEqual(BBSUploadMoveReport.message([.refused(name: "big.bin", reason: "it is over the 2 MB limit")],
                                                   area: "PARK"),
                       "big.bin was not moved: it is over the 2 MB limit.")
    }

    // MARK: Who sent a file in an area (retest 2026-10-10, finding 2)

    /// Moving an upload into an area keeps who sent it and when, for the
    /// operator. Move to Area used to forget both.
    func testAMovedUploadKeepsWhoSentIt() throws {
        library.addArea(name: "PARK", about: "", url: park)
        library.setInbox(url: inbox)
        library.saveUpload(name: "Photo.jpg", data: Data(count: 300), from: "K0EPI-3", at: arrived)
        library.moveUpload(named: "Photo.jpg", toArea: "PARK")

        let file = try XCTUnwrap(library.index.files(in: "PARK").first { $0.name == "Photo.jpg" })
        XCTAssertEqual(file.provenance, BBSFileProvenance(from: "K0EPI-3", receivedAt: arrived, movedFromInbox: true))

        relaunched = makeLibrary()
        relaunched.rescan()
        XCTAssertEqual(relaunched.index.files(in: "PARK").first?.provenance?.from, "K0EPI-3", "kept across a relaunch")
    }

    func testARenamedMoveKeepsItUnderTheNewName() throws {
        try Data("the old one".utf8).write(to: park.appendingPathComponent("Photo.jpg"))
        library.addArea(name: "PARK", about: "", url: park)
        library.setInbox(url: inbox)
        library.saveUpload(name: "Photo.jpg", data: Data(count: 300), from: "K0EPI-3", at: arrived)
        library.moveUpload(named: "Photo.jpg", toArea: "PARK")

        let files = library.index.files(in: "PARK")
        XCTAssertNil(files.first { $0.name == "Photo.jpg" }?.provenance, "the operator's own file")
        XCTAssertEqual(files.first { $0.name == "Photo-2.jpg" }?.provenance?.from, "K0EPI-3")
    }

    /// A trusted caller's upload straight into an area records it too.
    func testATrustedUploadRecordsWhoSentIt() throws {
        library.addArea(name: "PARK", about: "", url: park)
        library.setAcceptsTrustedUploads(true, area: "PARK")
        library.saveTrustedUpload(name: "net.txt", data: Data(count: 40), toArea: "PARK", from: "K0EPI-3", at: arrived)
        XCTAssertEqual(library.index.files(in: "PARK").first?.provenance,
                       BBSFileProvenance(from: "K0EPI-3", receivedAt: arrived, movedFromInbox: false))
    }

    /// A file that went away takes its record with it, so a later file of
    /// the same name is not credited to the earlier caller.
    func testAFileThatGoesTakesItsRecordWithIt() throws {
        library.addArea(name: "PARK", about: "", url: park)
        library.setInbox(url: inbox)
        library.saveUpload(name: "Photo.jpg", data: Data(count: 300), from: "K0EPI-3", at: arrived)
        library.moveUpload(named: "Photo.jpg", toArea: "PARK")
        try FileManager.default.removeItem(at: park.appendingPathComponent("Photo.jpg"))
        library.rescan()
        try Data(count: 10).write(to: park.appendingPathComponent("Photo.jpg"))
        library.rescan()
        XCTAssertNil(library.index.files(in: "PARK").first?.provenance)
    }

    /// The words on the area table's From column, for its tooltip.
    func testTheProvenanceSaysWhereItCameFrom() {
        let moved = BBSFileProvenance(from: "K0EPI-3", receivedAt: arrived, movedFromInbox: true)
        XCTAssertTrue(moved.help(inbox: "docs").hasPrefix("Uploaded by K0EPI-3, "))
        XCTAssertTrue(moved.help(inbox: "docs").hasSuffix(", moved from docs"))
        let direct = BBSFileProvenance(from: "K0EPI-3", receivedAt: arrived, movedFromInbox: false)
        XCTAssertFalse(direct.help(inbox: "docs").contains("moved"))
    }
}
