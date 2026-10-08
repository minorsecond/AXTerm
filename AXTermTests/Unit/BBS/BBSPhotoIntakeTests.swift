//
//  BBSPhotoIntakeTests.swift
//  AXTermTests
//
//  Photos added to a BBS area are sized first, with the same preview Send
//  File uses (operator, 2026-10-07: downloading photos from the BBS at a
//  park). A phone photo is megabytes, which is hours at the BBS's rate, so
//  the operator picks the size before callers ever see it listed.
//

import XCTest
import GRDB
import UniformTypeIdentifiers
@testable import AXTerm

@MainActor
final class BBSPhotoIntakeTests: XCTestCase {

    private var root: URL!
    private var store: SQLiteBBSMessageStore!
    private lazy var library = BBSFileLibrary(store: store)
    private static let photo: Data = SyntheticPhoto.data(width: 3000, height: 2000, seed: 5)!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbs-photo-intake-\(UUID().uuidString)")
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

    func testAddingAPhotoAsksForItsSizeAndAddsTheRest() throws {
        let area = try folder("ops")
        library.addArea(name: "OPS", about: "", url: area)
        let desktop = try folder("desktop")
        let photo = desktop.appendingPathComponent("IMG_1.jpg")
        let notes = desktop.appendingPathComponent("notes.txt")
        try Self.photo.write(to: photo)
        try Data("net".utf8).write(to: notes)

        let result = BBSFilePick.apply(.addFiles(area: "OPS"), urls: [photo, notes], library: library)

        guard case .sizePhotos(let photos, let message) = result else {
            return XCTFail("the photo waits for a size: \(result)")
        }
        XCTAssertEqual(photos.map(\.name), ["IMG_1.jpg"])
        XCTAssertEqual(photos.first?.data, Self.photo)
        XCTAssertEqual(photos.first?.area, "OPS")
        XCTAssertEqual(message, "Added 1 file to OPS.")
        XCTAssertEqual(library.index.files(in: "OPS").map(\.name), ["notes.txt"],
                       "nothing of the photo is shared until its size is chosen")
    }

    func testAnImageAlreadySmallerThanSmallGoesStraightIn() throws {
        let area = try folder("ops")
        library.addArea(name: "OPS", about: "", url: area)
        let icon = try folder("desktop").appendingPathComponent("icon.png")
        let small = try XCTUnwrap(SyntheticPhoto.data(width: 60, height: 60, seed: 2))
        XCTAssertLessThan(small.count, PhotoSendSize.small.byteBudget!)
        try small.write(to: icon)

        let result = BBSFilePick.apply(.addFiles(area: "OPS"), urls: [icon], library: library)

        XCTAssertEqual(result, .finished(message: "Added 1 file to OPS."))
    }

    func testThePhotoGoesInAtTheChosenSize() throws {
        let area = try folder("ops")
        library.addArea(name: "OPS", about: "", url: area)
        let pending = BBSPendingPhoto(name: "IMG_1.HEIC", data: Self.photo, area: "OPS")
        let prepared = PhotoSendChoice.prepare(original: Self.photo, name: pending.name, size: .small,
                                               format: .jpeg, keepsLocation: false)

        let outcome = BBSPhotoIntake.add(pending, as: prepared, library: library)

        XCTAssertEqual(outcome, .added(name: "IMG_1.jpg"))
        let stored = try Data(contentsOf: area.appendingPathComponent("IMG_1.jpg"))
        XCTAssertEqual(stored, prepared.data, "the bytes in the preview are the bytes callers get")
    }

    func testADroppedPhotoAlsoWaitsForItsSize() async throws {
        let area = try folder("ops")
        library.addArea(name: "OPS", about: "", url: area)
        let photo = try folder("desktop").appendingPathComponent("IMG_3.jpg")
        try Self.photo.write(to: photo)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: photo))

        let done = expectation(description: "drop handled")
        var photos: [BBSPendingPhoto] = []
        BBSFileDrop.add([provider], to: "OPS", library: library) { _, waiting in
            photos = waiting
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(photos.map(\.name), ["IMG_3.jpg"])
        XCTAssertTrue(library.index.files(in: "OPS").isEmpty)
    }

    // MARK: - From the photo library (operator, 2026-10-08: "shouldn't we
    // have an add photos button too, that opens the macos photo picker?")

    func testALibraryPhotoWaitsForItsSizeUnderAPickedName() throws {
        let area = try folder("ops")
        library.addArea(name: "OPS", about: "", url: area)
        let small = try XCTUnwrap(SyntheticPhoto.data(width: 60, height: 60, seed: 2))
        // 2026-10-08 14:42:10 UTC, 08:42:10 in Denver.
        let when = Date(timeIntervalSince1970: 1_791_470_530)

        let result = BBSPhotoIntake.addFromLibrary([(Self.photo, .heic), (small, .png), (nil, .jpeg)],
                                                   to: "OPS", library: library, at: when,
                                                   timeZone: TimeZone(identifier: "America/Denver")!)

        XCTAssertEqual(result.waiting.map(\.name), ["Photo-20261008-084210-1.heic"])
        XCTAssertEqual(result.waiting.first?.data, Self.photo)
        XCTAssertEqual(result.waiting.first?.area, "OPS")
        XCTAssertEqual(result.outcomes, [
            .added(name: "Photo-20261008-084210-2.png"),
            .refused(name: "Photo-20261008-084210-3.jpeg", reason: "it could not be read"),
        ], "a photo already smaller than Small goes straight in, as from Files")
        XCTAssertEqual(library.index.files(in: "OPS").map(\.name), ["Photo-20261008-084210-2.png"])
    }
}
