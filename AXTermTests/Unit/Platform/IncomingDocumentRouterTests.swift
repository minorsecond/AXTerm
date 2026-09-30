import XCTest
@testable import AXTerm

/// Files other apps hand to AXTerm: what is offered for them, and the copy
/// the app keeps while deciding.
final class IncomingDocumentRouterTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomingRouterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String, bytes: Int) -> IncomingDocumentRouter.StagedFile {
        IncomingDocumentRouter.StagedFile(
            id: UUID(), url: root.appendingPathComponent(name), folder: root, name: name,
            byteCount: bytes, isImage: ImageShrinker.isImage(named: name))
    }

    private func writeSource(_ name: String, _ contents: String = "73") throws -> URL {
        let url = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Choices

    func testWithNoSessionOnlyWinlinkIsOffered() {
        let choices = IncomingDocumentRouter.choices(for: file("a.pdf", bytes: 10_000),
                                                     winlinkAvailable: true, connectedCallsigns: [])
        XCTAssertEqual(choices, [.winlink(shrinksImage: false)])
    }

    func testEachConnectedStationIsAPacketChoice() {
        let choices = IncomingDocumentRouter.choices(for: file("a.pdf", bytes: 10_000),
                                                     winlinkAvailable: true,
                                                     connectedCallsigns: ["W0ARP-10", "k0nts-7"])
        XCTAssertEqual(choices, [.winlink(shrinksImage: false),
                                 .packet(callsign: "W0ARP-10"), .packet(callsign: "K0NTS-7")])
    }

    func testTheSameStationTwiceIsOneChoice() {
        let choices = IncomingDocumentRouter.choices(for: file("a.pdf", bytes: 10),
                                                     winlinkAvailable: false,
                                                     connectedCallsigns: ["W0ARP-10", "w0arp-10 ", ""])
        XCTAssertEqual(choices, [.packet(callsign: "W0ARP-10")])
    }

    func testWithoutAMailboxThereIsNoWinlinkChoice() {
        XCTAssertEqual(IncomingDocumentRouter.choices(for: file("a.pdf", bytes: 10),
                                                      winlinkAvailable: false, connectedCallsigns: []), [])
    }

    func testABigPhotoIsOfferedShrunk() {
        let choices = IncomingDocumentRouter.choices(for: file("IMG.HEIC", bytes: 3_000_000),
                                                     winlinkAvailable: true, connectedCallsigns: [])
        XCTAssertEqual(choices, [.winlink(shrinksImage: true)])
    }

    func testASmallPhotoIsNotDescribedAsShrunk() {
        let choices = IncomingDocumentRouter.choices(for: file("IMG.jpg", bytes: 30_000),
                                                     winlinkAvailable: true, connectedCallsigns: [])
        XCTAssertEqual(choices, [.winlink(shrinksImage: false)])
    }

    /// A video will never fit a Winlink message and is not offered for one,
    /// though it can still go over packet.
    func testAHugeNonPhotoIsOnlyOfferedForPacket() {
        let choices = IncomingDocumentRouter.choices(
            for: file("clip.mov", bytes: IncomingDocumentRouter.maxWinlinkIntakeBytes + 1),
            winlinkAvailable: true, connectedCallsigns: ["W0ARP-10"])
        XCTAssertEqual(choices, [.packet(callsign: "W0ARP-10")])
    }

    func testTitlesAndDetails() {
        XCTAssertEqual(IncomingDocumentRouter.title(for: .winlink(shrinksImage: false)),
                       "Attach to a new Winlink message")
        XCTAssertEqual(IncomingDocumentRouter.title(for: .packet(callsign: "W0ARP-10")),
                       "Send to W0ARP-10 over packet")
        XCTAssertNil(IncomingDocumentRouter.detail(for: .winlink(shrinksImage: false), file: file("a.txt", bytes: 10)))
        XCTAssertNotNil(IncomingDocumentRouter.detail(for: .winlink(shrinksImage: true), file: file("a.jpg", bytes: 3_000_000)))
        let over = IncomingDocumentRouter.detail(for: .winlink(shrinksImage: false), file: file("a.pdf", bytes: 500_000))
        XCTAssertTrue(over?.contains("over Winlink") ?? false, over ?? "")
        XCTAssertNotNil(IncomingDocumentRouter.detail(for: .packet(callsign: "X"), file: file("a.txt", bytes: 1)))
    }

    func testChoiceIdentitiesAreDistinct() {
        let ids = [IncomingDocumentRouter.Choice.winlink(shrinksImage: true), .packet(callsign: "A"), .packet(callsign: "B")]
            .map(\.id)
        XCTAssertEqual(Set(ids).count, 3)
    }

    // MARK: - Staging

    func testStagingCopiesTheFileIn() throws {
        let source = try writeSource("report.txt", "hello")
        let inbox = root.appendingPathComponent("inbox")
        let staged = try IncomingDocumentRouter.stage(source, inbox: inbox, ownInbox: nil)
        XCTAssertEqual(staged.name, "report.txt")
        XCTAssertEqual(staged.byteCount, 5)
        XCTAssertFalse(staged.isImage)
        XCTAssertEqual(try Data(contentsOf: staged.url), Data("hello".utf8))
        XCTAssertTrue(IncomingDocumentRouter.isInside(staged.url, folder: inbox))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "another app's file is left alone")
        XCTAssertEqual(IncomingDocumentRouter.contents(of: staged),
                       ComposeIncomingFile(name: "report.txt", data: Data("hello".utf8)))
    }

    func testTwoFilesWithOneNameDoNotCollide() throws {
        let inbox = root.appendingPathComponent("inbox")
        let a = try IncomingDocumentRouter.stage(try writeSource("same.txt", "a"), inbox: inbox, ownInbox: nil)
        let b = try IncomingDocumentRouter.stage(try writeSource("same.txt", "b"), inbox: inbox, ownInbox: nil)
        XCTAssertNotEqual(a.url, b.url)
        XCTAssertEqual(try Data(contentsOf: a.url), Data("a".utf8))
        XCTAssertEqual(try Data(contentsOf: b.url), Data("b".utf8))
    }

    /// iOS "copy to" puts the file in Documents/Inbox, which the Files app
    /// shows. Once the app has its own copy, that one goes.
    func testACopyInTheAppsOwnInboxIsRemoved() throws {
        let ownInbox = root.appendingPathComponent("Documents/Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: ownInbox, withIntermediateDirectories: true)
        let source = ownInbox.appendingPathComponent("photo.jpg")
        try Data("jpeg".utf8).write(to: source)
        let staged = try IncomingDocumentRouter.stage(source, inbox: root.appendingPathComponent("inbox"),
                                                      ownInbox: ownInbox)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))
        XCTAssertTrue(staged.isImage)
    }

    func testAFileThatCannotBeReadLeavesNothingBehind() {
        let inbox = root.appendingPathComponent("inbox")
        XCTAssertThrowsError(try IncomingDocumentRouter.stage(
            root.appendingPathComponent("missing.txt"), inbox: inbox, ownInbox: nil))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testDiscardRemovesTheCopy() throws {
        let staged = try IncomingDocumentRouter.stage(try writeSource("a.txt"),
                                                      inbox: root.appendingPathComponent("inbox"), ownInbox: nil)
        IncomingDocumentRouter.discard(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.folder.path))
    }

    func testPurgeRemovesOnlyOldCopies() throws {
        let inbox = root.appendingPathComponent("inbox")
        let old = try IncomingDocumentRouter.stage(try writeSource("old.txt"), inbox: inbox, ownInbox: nil)
        let new = try IncomingDocumentRouter.stage(try writeSource("new.txt"), inbox: inbox, ownInbox: nil)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3 * 86_400)],
                                              ofItemAtPath: old.folder.path)
        IncomingDocumentRouter.purge(inbox: inbox, olderThan: 86_400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.url.path))
    }

    func testPurgingAMissingInboxIsHarmless() {
        IncomingDocumentRouter.purge(inbox: root.appendingPathComponent("never-made"), olderThan: 0)
    }

    func testInsideIsAboutFoldersNotPrefixes() {
        let folder = URL(fileURLWithPath: "/tmp/Inbox")
        XCTAssertTrue(IncomingDocumentRouter.isInside(URL(fileURLWithPath: "/tmp/Inbox/a.txt"), folder: folder))
        XCTAssertFalse(IncomingDocumentRouter.isInside(URL(fileURLWithPath: "/tmp/Inbox2/a.txt"), folder: folder))
        XCTAssertFalse(IncomingDocumentRouter.isInside(URL(fileURLWithPath: "/tmp/a.txt"), folder: folder))
    }
}
