import GRDB
import XCTest
@testable import AXTerm

/// `--keep-data`: a test-mode instance that keeps its settings and database
/// across launches.
///
/// Test mode starts clean on purpose, so a rig run never inherits the last
/// one. A (705) is a test-mode instance that runs for days with a radio, a
/// mailbox and Winlink set up, and on 2026-10-09 a relaunch onto a new build
/// erased all of it. Without the flag nothing changes.
final class TestModeKeepDataTests: XCTestCase {
    private var removals: [() -> Void] = []

    override func tearDown() {
        removals.forEach { $0() }
        removals = []
        super.tearDown()
    }

    func testTheFlagIsReadFromTheArguments() {
        XCTAssertTrue(TestModeConfiguration.keepsData(
            arguments: ["AXTerm", "--test-mode", "--instance-name", "Station A", "--keep-data"]))
        XCTAssertFalse(TestModeConfiguration.keepsData(
            arguments: ["AXTerm", "--test-mode", "--instance-name", "Station A"]))
    }

    // MARK: - Connecting at launch

    /// A kept instance connects its own radios, as a normal install does.
    /// The rig's fixed KISS endpoint is for a fresh rig instance; on
    /// 2026-10-09 A (705) relaunched with `--keep-data` dialed localhost:8001
    /// instead of its IC-705.
    func testAKeptInstanceConnectsItsOwnRadios() {
        XCTAssertEqual(TestModeConfiguration.launchConnection(
            isTestMode: true, keepsData: true, hasRigRadios: false,
            autoConnectSetting: true, autoConnectFlag: false), .settings)
    }

    func testAFreshRigInstanceStillUsesTheRigEndpoint() {
        XCTAssertEqual(TestModeConfiguration.launchConnection(
            isTestMode: true, keepsData: false, hasRigRadios: false,
            autoConnectSetting: false, autoConnectFlag: true), .rigEndpoint)
        XCTAssertEqual(TestModeConfiguration.launchConnection(
            isTestMode: true, keepsData: false, hasRigRadios: true,
            autoConnectSetting: false, autoConnectFlag: true), .settings)
    }

    func testNothingConnectsUnlessAskedTo() {
        XCTAssertEqual(TestModeConfiguration.launchConnection(
            isTestMode: true, keepsData: true, hasRigRadios: false,
            autoConnectSetting: false, autoConnectFlag: false), .none)
        XCTAssertEqual(TestModeConfiguration.launchConnection(
            isTestMode: false, keepsData: false, hasRigRadios: false,
            autoConnectSetting: true, autoConnectFlag: false), .settings)
    }

    // MARK: - Settings

    private func suiteName() -> String {
        TestDefaults.name("keepdata")
    }

    func testAKeptSuiteHoldsWhatTheLastLaunchWrote() {
        let name = suiteName()
        UserDefaults(suiteName: name)!.set("K0EPI-2", forKey: "onAir")
        let reopened = AppEnvironment.openSuite(named: name, wipe: false)
        XCTAssertEqual(reopened.string(forKey: "onAir"), "K0EPI-2")
    }

    func testAWipedSuiteStartsEmpty() {
        let name = suiteName()
        UserDefaults(suiteName: name)!.set("K0EPI-2", forKey: "onAir")
        let reopened = AppEnvironment.openSuite(named: name, wipe: true)
        XCTAssertNil(reopened.string(forKey: "onAir"))
    }

    // MARK: - Database

    private func instanceID() throws -> String {
        let id = "keepdata-\(UUID().uuidString)"
        let url = try DatabaseManager.ephemeralDatabaseURL(instanceID: id)
        removals.append { DatabaseManager.removeEphemeralDatabase(at: url) }
        return id
    }

    private func writeMarker(_ queue: DatabaseQueue) throws {
        try queue.write { try $0.execute(sql: "CREATE TABLE marker (x INTEGER); INSERT INTO marker VALUES (1)") }
    }

    private func hasMarker(_ queue: DatabaseQueue) throws -> Bool {
        try queue.read { try $0.tableExists("marker") }
    }

    @MainActor
    func testAKeptDatabaseHoldsWhatTheLastLaunchWrote() throws {
        let id = try instanceID()
        try writeMarker(try DatabaseManager.makeEphemeralDatabaseQueue(instanceID: id))
        let reopened = try DatabaseManager.makeEphemeralDatabaseQueue(instanceID: id, keepExisting: true)
        XCTAssertTrue(try hasMarker(reopened))
    }

    @MainActor
    func testWithoutTheFlagTheDatabaseStartsFresh() throws {
        let id = try instanceID()
        try writeMarker(try DatabaseManager.makeEphemeralDatabaseQueue(instanceID: id))
        let reopened = try DatabaseManager.makeEphemeralDatabaseQueue(instanceID: id)
        XCTAssertFalse(try hasMarker(reopened))
    }

    /// A kept database left alone for more than a day is still the
    /// instance's own, so the stale-file sweep spares it.
    @MainActor
    func testAKeptDatabaseOlderThanTheRetentionIsNotSwept() throws {
        let id = try instanceID()
        try writeMarker(try DatabaseManager.makeEphemeralDatabaseQueue(instanceID: id))
        let url = try DatabaseManager.ephemeralDatabaseURL(instanceID: id)
        let old = Date().addingTimeInterval(-DatabaseManager.ephemeralRetention - 3600)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path + suffix)
        }
        let reopened = try DatabaseManager.makeEphemeralDatabaseQueue(instanceID: id, keepExisting: true)
        XCTAssertTrue(try hasMarker(reopened))
    }
}
