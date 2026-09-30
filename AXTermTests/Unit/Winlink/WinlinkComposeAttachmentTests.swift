import GRDB
import UniformTypeIdentifiers
import XCTest
@testable import AXTerm

/// Attaching to a Winlink message: every source goes through one planner, a
/// photo that would not fit is offered shrunk, Send Original undoes it, and
/// nothing is dropped or queued over the budget.
@MainActor
final class WinlinkComposeAttachmentTests: XCTestCase {

    private static let photo: Data = SyntheticPhoto.data(width: 2000, height: 1500, seed: 7)!
    private static let photoWithLocation: Data =
        SyntheticPhoto.data(width: 2000, height: 1500, seed: 8, gps: SyntheticPhoto.gps)!

    private var defaults: UserDefaults!
    private var store: SQLiteWinlinkStore!

    override func setUp() async throws {
        defaults = TestDefaults.make("ComposeAttachments")
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        store = SQLiteWinlinkStore(dbQueue: queue)
    }

    private func makeViewModel(draftMID: String? = nil) -> WinlinkComposeViewModel {
        WinlinkComposeViewModel(store: store, myCallsign: "K0EPI", existingDraftMID: draftMID,
                                defaults: defaults)
    }

    private func savedEmptyDraft() throws -> String {
        let draft = WinlinkB2Message(mid: WinlinkB2Message.generateMID(callsign: "K0EPI"), date: Date(),
                                     type: .privateMessage, from: "K0EPI", to: [], cc: [], subject: "",
                                     mbo: "K0EPI", body: Data(), attachments: [])
        try store.saveDraft(draft)
        return draft.mid
    }

    // MARK: - Sources

    /// Files, the photo library, the camera, drag and drop and paste all hand
    /// the model the same thing: a name and bytes.
    func testEverySourceArrivesTheSameWay() async throws {
        let vm = makeViewModel()
        let file = ComposeIncomingFile(name: "notes.txt", data: Data("73 de K0EPI".utf8))
        let library = ComposeIncomingFile(name: ComposeAttachmentIntake.photoName(index: 1, contentType: .jpeg),
                                          data: try XCTUnwrap(SyntheticPhoto.data(width: 200, height: 150)))
        let camera = ComposeIncomingFile(name: ComposeAttachmentIntake.photoName(index: 1, contentType: .jpeg),
                                         data: try XCTUnwrap(SyntheticPhoto.data(width: 180, height: 120, seed: 4)))
        let png = try XCTUnwrap(SyntheticPhoto.data(width: 60, height: 40, type: .png))
        let pasted = await ComposeAttachmentIntake.load(
            [NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)])

        await vm.addAttachments([file, library, camera] + pasted.files)

        XCTAssertEqual(vm.attachments.map(\.name), ["notes.txt", "Photo 1.jpeg", "Photo 2.jpeg", "Pasted.png"],
                       "the camera's photo does not overwrite the library's")
        XCTAssertEqual(vm.attachments.map(\.change), [.none, .none, .none, .none], "all small enough as they are")
        XCTAssertEqual(vm.preparingCount, 0)
    }

    func testTheSynchronousPathPlansTheSameWay() {
        let vm = makeViewModel()
        vm.addAttachment(name: "IMG_0001.jpg", data: Self.photo)
        XCTAssertTrue(vm.attachments[0].isShrunk)
    }

    // MARK: - Shrinking

    func testAPhotoOverTheBudgetIsShrunkByDefault() async throws {
        XCTAssertGreaterThan(Self.photo.count, WinlinkComposeViewModel.messageSizeBudget)
        let vm = makeViewModel()
        await vm.addAttachments([ComposeIncomingFile(name: "IMG_0001.HEIC", data: Self.photo)])

        let item = try XCTUnwrap(vm.attachments.first)
        XCTAssertTrue(item.isShrunk)
        XCTAssertEqual(item.name, "IMG_0001.jpg")
        XCTAssertLessThanOrEqual(item.data.count, ComposeAttachmentPlanner.photoTargetBytes)
        XCTAssertEqual(item.original?.data, Self.photo, "the original is kept for Send Original")
        XCTAssertEqual(item.original?.name, "IMG_0001.HEIC")
        XCTAssertTrue(item.summary.hasPrefix("Shrunk to "), item.summary)
        XCTAssertTrue(item.summary.contains(" from "), item.summary)
        XCTAssertFalse(vm.isOverBudget)
    }

    func testTheChipSaysWhatHappened() {
        let shrunk = WinlinkComposeViewModel.AttachmentItem(
            name: "a.jpg", data: Data(count: 38 * 1024), original: (name: "a.heic", data: Data(count: 3_100_000)),
            change: .shrunk(pixelWidth: 1024, pixelHeight: 768))
        XCTAssertEqual(shrunk.summary, "Shrunk to \(ByteCount.string(38 * 1024)) from \(ByteCount.string(3_100_000))")
        let zipped = WinlinkComposeViewModel.AttachmentItem(
            name: "a.txt.zip", data: Data(count: 1000), original: (name: "a.txt", data: Data(count: 4000)))
        XCTAssertEqual(zipped.change, .zipped, "an original with no change named means zipped, as it always did")
        XCTAssertTrue(zipped.summary.contains("\u{2192}"))
        let plain = WinlinkComposeViewModel.AttachmentItem(name: "a.bin", data: Data(count: 10))
        XCTAssertEqual(plain.summary, ByteCount.string(10))
        XCTAssertFalse(plain.canSendOriginal)
    }

    func testSendOriginalPutsBackTheExactPhoto() async throws {
        let vm = makeViewModel()
        vm.toText = "W1AW"
        await vm.addAttachments([ComposeIncomingFile(name: "IMG_0001.HEIC", data: Self.photo)])
        let id = try XCTUnwrap(vm.attachments.first?.id)

        vm.sendOriginal(id: id)

        XCTAssertEqual(vm.attachments[0].name, "IMG_0001.HEIC")
        XCTAssertEqual(vm.attachments[0].data, Self.photo)
        XCTAssertEqual(vm.attachments[0].change, .none)
        XCTAssertTrue(vm.isOverBudget)
        XCTAssertNil(vm.queueForSending(), "over the budget, queueing is refused")
        XCTAssertTrue(vm.validationError?.contains("limit") ?? false, vm.validationError ?? "")
    }

    func testShrinkToFitAfterSendingTheOriginal() async throws {
        let vm = makeViewModel()
        await vm.addAttachments([ComposeIncomingFile(name: "IMG_0001.HEIC", data: Self.photo)])
        let id = try XCTUnwrap(vm.attachments.first?.id)
        vm.sendOriginal(id: id)
        XCTAssertTrue(vm.isOverBudget)

        await vm.shrinkToFit(id: id)

        XCTAssertTrue(vm.attachments[0].isShrunk)
        XCTAssertEqual(vm.attachments[0].id, id, "the same chip, changed in place")
        XCTAssertFalse(vm.isOverBudget)
        XCTAssertEqual(vm.preparingCount, 0)
    }

    func testSeveralPhotosAllFitTheirShareOfTheBudget() async throws {
        let vm = makeViewModel()
        let photos = (1...3).map { ComposeIncomingFile(name: "Photo \($0).heic", data: Self.photo) }
        await vm.addAttachments(photos)

        XCTAssertEqual(vm.attachments.count, 3)
        XCTAssertTrue(vm.attachments.allSatisfy(\.isShrunk))
        XCTAssertEqual(vm.attachments.map(\.name), ["Photo 1.jpg", "Photo 2.jpg", "Photo 3.jpg"])
        XCTAssertLessThanOrEqual(vm.totalSizeBytes, WinlinkComposeViewModel.messageSizeBudget)
    }

    func testTheSamePhotoTwiceGetsTwoNames() async {
        let vm = makeViewModel()
        let photo = ComposeIncomingFile(name: "IMG.heic", data: Self.photo)
        await vm.addAttachments([photo, photo])
        XCTAssertEqual(vm.attachments.map(\.name), ["IMG.jpg", "IMG 2.jpg"])
    }

    func testSendOriginalRenamesAroundAnotherAttachment() async throws {
        let vm = makeViewModel()
        await vm.addAttachments([ComposeIncomingFile(name: "IMG.heic", data: Self.photo),
                                 ComposeIncomingFile(name: "IMG.heic", data: Data("not a photo".utf8))])
        XCTAssertEqual(vm.attachments.map(\.name), ["IMG.jpg", "IMG.heic"])
        vm.sendOriginal(id: vm.attachments[0].id)
        XCTAssertEqual(vm.attachments.map(\.name), ["IMG 2.heic", "IMG.heic"], "two chips never share a name")
    }

    /// No room left: the photo goes in as it is with a reason, and the gauge
    /// turns red. It is never dropped.
    func testAPhotoWithNoRoomLeftIsAttachedWithANote() async throws {
        let vm = makeViewModel()
        vm.bodyText = String(repeating: "x", count: WinlinkComposeViewModel.messageSizeBudget - 2_000)
        await vm.addAttachments([ComposeIncomingFile(name: "IMG.heic", data: Self.photo)])

        let item = try XCTUnwrap(vm.attachments.first)
        XCTAssertEqual(item.data, Self.photo)
        XCTAssertNotNil(item.note)
        XCTAssertTrue(vm.isOverBudget)
        XCTAssertEqual(WinlinkComposeWindow.chipExplanation(for: item), item.note)
        XCTAssertEqual(WinlinkComposeWindow.chipSymbol(for: item), "exclamationmark.triangle")
    }

    func testAnAnimatedGIFGoesAsItIsWithANote() async {
        let vm = makeViewModel()
        let gif = SyntheticPhoto.animatedGIF(width: 900, height: 700)
        XCTAssertGreaterThan(gif.count, 20_000)
        // Room for a shrunk photo, but not for this.
        vm.bodyText = String(repeating: "x", count: WinlinkComposeViewModel.messageSizeBudget - 20_000)
        await vm.addAttachments([ComposeIncomingFile(name: "loop.gif", data: gif)])
        XCTAssertEqual(vm.attachments.first?.data, gif)
        XCTAssertNotNil(vm.attachments.first?.note)
    }

    // MARK: - Location

    func testAPhotoLosesItsLocationUnlessKept() async throws {
        let vm = makeViewModel()
        await vm.addAttachments([ComposeIncomingFile(name: "IMG.heic", data: Self.photoWithLocation)])
        XCTAssertFalse(ImageShrinker.containsLocation(try XCTUnwrap(vm.attachments.first?.data)))
    }

    func testKeepPhotoLocationKeepsItAndIsRemembered() async throws {
        let vm = makeViewModel()
        vm.keepsPhotoLocation = true
        await vm.addAttachments([ComposeIncomingFile(name: "IMG.heic", data: Self.photoWithLocation)])
        XCTAssertTrue(ImageShrinker.containsLocation(try XCTUnwrap(vm.attachments.first?.data)))
        XCTAssertTrue(makeViewModel().keepsPhotoLocation, "the choice carries to the next message")
    }

    func testASmallPhotoWithALocationKeepsItsPixels() async throws {
        let small = try XCTUnwrap(SyntheticPhoto.data(width: 300, height: 200, quality: 0.5, gps: SyntheticPhoto.gps))
        let vm = makeViewModel()
        await vm.addAttachments([ComposeIncomingFile(name: "small.jpg", data: small)])
        let item = try XCTUnwrap(vm.attachments.first)
        XCTAssertEqual(item.change, .locationRemoved)
        XCTAssertEqual(item.name, "small.jpg", "not renamed: it is still the same JPEG")
        XCTAssertFalse(ImageShrinker.containsLocation(item.data))
        XCTAssertTrue(item.summary.contains("location removed"), item.summary)
        vm.sendOriginal(id: item.id)
        XCTAssertEqual(vm.attachments[0].data, small)
    }

    // MARK: - Things that are never changed

    func testFormXMLIsNeverTouched() async {
        let xml = Data(String(repeating: "<field>value</field>\n", count: 400).utf8)
        let vm = makeViewModel()
        await vm.addAttachments([ComposeIncomingFile(name: "RMS_Express_Form_ICS213.xml", data: xml)])
        XCTAssertEqual(vm.attachments.first?.name, "RMS_Express_Form_ICS213.xml")
        XCTAssertEqual(vm.attachments.first?.data, xml)
    }

    func testANonImageNamedLikeAPhotoIsNotReencoded() async {
        let vm = makeViewModel()
        let bytes = Data("definitely text".utf8)
        await vm.addAttachments([ComposeIncomingFile(name: "trick.jpg", data: bytes)])
        XCTAssertEqual(vm.attachments.first?.data, bytes)
        XCTAssertNil(vm.attachments.first?.note)
    }

    // MARK: - Problems and persistence

    func testUnreadableFilesAreNamed() {
        let vm = makeViewModel()
        vm.reportUnreadable([])
        XCTAssertNil(vm.attachmentProblem, "nothing to report, nothing said")
        vm.reportUnreadable(["a.pdf", "b.jpg"])
        XCTAssertEqual(vm.attachmentProblem, "Could not read: a.pdf, b.jpg")
    }

    func testRemovingAnAttachment() async {
        let vm = makeViewModel()
        await vm.addAttachments([ComposeIncomingFile(name: "a.txt", data: Data("a".utf8)),
                                 ComposeIncomingFile(name: "b.txt", data: Data("b".utf8))])
        vm.removeAttachment(id: vm.attachments[0].id)
        XCTAssertEqual(vm.attachments.map(\.name), ["b.txt"])
    }

    func testDraftContentsAreSavedBeforeAnythingIsAddressed() async throws {
        let mid = try savedEmptyDraft()
        let vm = makeViewModel(draftMID: mid)
        await vm.addAttachments([ComposeIncomingFile(name: "IMG.heic", data: Self.photo)])
        XCTAssertTrue(vm.saveDraftContents())
        let stored = try XCTUnwrap(try store.message(mid: mid))
        XCTAssertEqual(stored.message.attachments.map(\.name), ["IMG.jpg"])
        XCTAssertEqual(stored.message.attachments.first?.data, vm.attachments.first?.data)
    }

    func testDraftContentsNeedADraftRow() {
        XCTAssertFalse(makeViewModel().saveDraftContents())
    }

    func testQueueingSendsTheShrunkPhoto() async throws {
        let mid = try savedEmptyDraft()
        let vm = makeViewModel(draftMID: mid)
        vm.toText = "W1AW"
        vm.subject = "Photo"
        await vm.addAttachments([ComposeIncomingFile(name: "IMG.heic", data: Self.photo)])
        XCTAssertEqual(vm.queueForSending(), mid)
        let stored = try XCTUnwrap(try store.message(mid: mid))
        XCTAssertLessThanOrEqual(stored.message.attachments[0].data.count, ComposeAttachmentPlanner.photoTargetBytes)
    }
}
