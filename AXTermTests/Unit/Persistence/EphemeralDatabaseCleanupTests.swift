//
//  EphemeralDatabaseCleanupTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

/// Ephemeral test databases are named after the test process, so nothing ever
/// reuses a name and nothing but these routines ever deletes one. A regression
/// here is invisible until the volume fills and an unrelated write dies with
/// `SQLITE_FULL`, so the collection rules are pinned down explicitly.
final class EphemeralDatabaseCleanupTests: XCTestCase {
    private var folder: URL!
    private var created: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = try DatabaseManager.ephemeralDatabaseFolder()
    }

    override func tearDownWithError() throws {
        for url in created {
            try? FileManager.default.removeItem(at: url)
        }
        created = []
        try super.tearDownWithError()
    }

    /// Writes a file into the shared ephemeral folder, aged `age` seconds back.
    /// Names are unique per test run so a concurrent instance is never touched.
    @discardableResult
    private func makeFile(_ suffix: String, age: TimeInterval) throws -> URL {
        let name = "\(DatabaseManager.ephemeralPrefix)case-\(UUID().uuidString)\(suffix)"
        let url = folder.appendingPathComponent(name)
        try Data([0x00]).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
        created.append(url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Sidecars

    func testRemoveDeletesWalAndShmAlongsideDatabase() throws {
        let db = folder.appendingPathComponent(
            "\(DatabaseManager.ephemeralPrefix)sidecars-\(UUID().uuidString).sqlite")
        let wal = URL(fileURLWithPath: db.path + "-wal")
        let shm = URL(fileURLWithPath: db.path + "-shm")
        for url in [db, wal, shm] {
            try Data([0x00]).write(to: url)
            created.append(url)
        }

        DatabaseManager.removeEphemeralDatabase(at: db)

        XCTAssertFalse(exists(db), "database should be deleted")
        XCTAssertFalse(exists(wal), "-wal sidecar must not be stranded")
        XCTAssertFalse(exists(shm), "-shm sidecar must not be stranded")
    }

    func testRemoveSucceedsWhenSidecarsAreAbsent() throws {
        let db = folder.appendingPathComponent(
            "\(DatabaseManager.ephemeralPrefix)lone-\(UUID().uuidString).sqlite")
        try Data([0x00]).write(to: db)
        created.append(db)

        DatabaseManager.removeEphemeralDatabase(at: db)

        XCTAssertFalse(exists(db))
    }

    // MARK: - Sweep

    func testSweepReclaimsAbandonedDatabasesAndSidecars() throws {
        let age = DatabaseManager.ephemeralRetention + 3600
        let db = try makeFile(".sqlite", age: age)
        let wal = try makeFile(".sqlite-wal", age: age)
        let shm = try makeFile(".sqlite-shm", age: age)

        DatabaseManager.sweepStaleEphemeralDatabases()

        XCTAssertFalse(exists(db))
        XCTAssertFalse(exists(wal))
        XCTAssertFalse(exists(shm))
    }

    /// The guarantee that makes an age-based sweep safe: a sibling instance
    /// writing to its own database in the shared folder is never collected.
    func testSweepSparesRecentlyTouchedDatabases() throws {
        let live = try makeFile(".sqlite", age: 60)
        let liveWal = try makeFile(".sqlite-wal", age: 0)

        DatabaseManager.sweepStaleEphemeralDatabases()

        XCTAssertTrue(exists(live), "a database touched a minute ago is still in use")
        XCTAssertTrue(exists(liveWal), "an active -wal must survive the sweep")
    }

    func testSweepIgnoresFilesOutsideTheEphemeralNamespace() throws {
        let name = "unrelated-\(UUID().uuidString).sqlite"
        let url = folder.appendingPathComponent(name)
        try Data([0x00]).write(to: url)
        created.append(url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-(DatabaseManager.ephemeralRetention + 3600))],
            ofItemAtPath: url.path
        )

        DatabaseManager.sweepStaleEphemeralDatabases()

        XCTAssertTrue(exists(url), "the sweep must only claim files it owns")
    }

    func testSweepLeavesBoundaryAgedFilesAlone() throws {
        // Just inside the window: proves the comparison is not inverted.
        let fresh = try makeFile(".sqlite", age: DatabaseManager.ephemeralRetention - 600)

        DatabaseManager.sweepStaleEphemeralDatabases()

        XCTAssertTrue(exists(fresh))
    }
}
