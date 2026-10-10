import XCTest
import GRDB
@testable import AXTerm

/// Trusted callers may upload straight into an area (home retest
/// 2026-10-10, finding 11).
///
/// Uploads stay in the inbox by default, because anything in an area is
/// served unattended under the operator's callsign. The operator can trust
/// some callers (their own callsigns always), and switch an area to take
/// those callers' uploads; everyone else still lands in the inbox.
@MainActor
final class BBSTrustedUploadsTests: XCTestCase {

    private var root: URL!
    private var park: URL!
    private var inbox: URL!
    private var store: SQLiteBBSMessageStore!
    private lazy var library: BBSFileLibrary = BBSFileLibrary(store: store)
    private var relaunched: BBSFileLibrary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bbs-trusted-\(UUID().uuidString)")
        park = root.appendingPathComponent("park")
        inbox = root.appendingPathComponent("inbox")
        for folder in [park!, inbox!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        store = SQLiteBBSMessageStore(dbQueue: queue)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Who is trusted

    /// The operator's own callsign, at any SSID, is trusted without being
    /// listed: their iPad at the park is them.
    func testTheOperatorsOwnCallsignIsTrusted() {
        XCTAssertTrue(BBSTrust.isTrusted("K0EPI-3", station: "K0EPI", list: []))
        XCTAssertTrue(BBSTrust.isTrusted("k0epi", station: "K0EPI-4", list: []))
        XCTAssertFalse(BBSTrust.isTrusted("W0ARP-1", station: "K0EPI", list: []))
    }

    /// A listed callsign without an SSID covers every SSID; with one, only
    /// that station.
    func testTheListMatchesByCallsign() {
        XCTAssertTrue(BBSTrust.isTrusted("W0ARP-1", station: "K0EPI", list: ["W0ARP"]))
        XCTAssertTrue(BBSTrust.isTrusted("W0ARP-1", station: "K0EPI", list: ["w0arp-1"]))
        XCTAssertFalse(BBSTrust.isTrusted("W0ARP-2", station: "K0EPI", list: ["W0ARP-1"]))
    }

    func testSettingsKeepTheList() {
        let defaults = TestDefaults.make("bbs-trusted-settings")
        let settings = BBSSettings(defaults: defaults)
        XCTAssertTrue(settings.trustedCallers.isEmpty)
        settings.trustedCallers = ["W0ARP", "N0CALL-7"]
        XCTAssertEqual(BBSSettings(defaults: defaults).trustedCallers, ["W0ARP", "N0CALL-7"])
    }

    // MARK: Areas

    func testAnAreaTakesTrustedUploadsOnlyWhenSwitchedOn() {
        library.addArea(name: "PARK", about: "", url: park)
        XCTAssertEqual(library.index.areas.first?.acceptsTrustedUploads, false)

        library.setAcceptsTrustedUploads(true, area: "PARK")
        XCTAssertEqual(library.index.areas.first?.acceptsTrustedUploads, true)

        relaunched = BBSFileLibrary(store: store)
        relaunched.rescan()
        XCTAssertEqual(relaunched.index.areas.first?.acceptsTrustedUploads, true, "kept across a relaunch")
    }

    /// Changing an area's description or folder keeps the switch.
    func testTheSwitchSurvivesOtherChangesToTheArea() {
        library.addArea(name: "PARK", about: "", url: park)
        library.setAcceptsTrustedUploads(true, area: "PARK")
        library.relocateArea(name: "PARK", url: park)
        XCTAssertEqual(library.index.areas.first?.acceptsTrustedUploads, true)
    }

    func testATrustedUploadGoesIntoTheAreaAndNeverReplaces() throws {
        library.addArea(name: "PARK", about: "", url: park)
        library.setInbox(url: inbox)
        library.setAcceptsTrustedUploads(true, area: "PARK")

        XCTAssertEqual(library.saveTrustedUpload(name: "photo.jpg", data: Data(count: 50), toArea: "PARK"), "photo.jpg")
        XCTAssertEqual(library.saveTrustedUpload(name: "photo.jpg", data: Data(count: 60), toArea: "PARK"), "photo-2.jpg")
        XCTAssertEqual(library.index.files(in: "PARK").map(\.name), ["photo-2.jpg", "photo.jpg"])
        XCTAssertTrue(library.uploads.isEmpty, "nothing in the inbox")
    }

    func testAnAreaThatDoesNotTakeUploadsIsNotWrittenTo() {
        library.addArea(name: "PARK", about: "", url: park)
        XCTAssertNil(library.saveTrustedUpload(name: "photo.jpg", data: Data(count: 50), toArea: "PARK"))
        XCTAssertTrue(library.index.files(in: "PARK").isEmpty)
    }

    // MARK: Where an upload goes

    private let areas = [BBSFileArea(name: "PARK", acceptsTrustedUploads: true), BBSFileArea(name: "OPS")]

    func testATrustedCallerNamingAnAreaThatTakesUploadsGetsIt() {
        XCTAssertEqual(BBSUploadTarget.resolve(area: "PARK", caller: "K0EPI-3", station: "K0EPI",
                                               trusted: [], areas: areas),
                       BBSUploadTarget(area: "PARK", note: "Your upload goes straight into PARK."))
    }

    /// Anyone else is told it goes to the inbox, in the same words whether
    /// they are not trusted or the area does not take uploads.
    func testEveryoneElseGoesToTheInboxAndIsTold() {
        let inbox = BBSUploadTarget(area: nil, note: "Uploads go to the sysop's inbox, not into PARK.")
        XCTAssertEqual(BBSUploadTarget.resolve(area: "PARK", caller: "W0ARP-1", station: "K0EPI",
                                               trusted: [], areas: areas), inbox)
        XCTAssertEqual(BBSUploadTarget.resolve(area: "OPS", caller: "K0EPI-3", station: "K0EPI",
                                               trusted: [], areas: areas),
                       BBSUploadTarget(area: nil, note: "Uploads go to the sysop's inbox, not into OPS."))
        XCTAssertEqual(BBSUploadTarget.resolve(area: "BEACH", caller: "K0EPI-3", station: "K0EPI",
                                               trusted: [], areas: areas),
                       BBSUploadTarget(area: nil, note: "There is no area called BEACH. Uploads go to the sysop's inbox."))
        XCTAssertEqual(BBSUploadTarget.resolve(area: nil, caller: "K0EPI-3", station: "K0EPI",
                                               trusted: [], areas: areas),
                       BBSUploadTarget(area: nil, note: nil))
    }

    // MARK: The list's editor

    func testAnEntryIsACallsignWithAnOptionalSSID() {
        XCTAssertEqual(BBSTrust.entry(from: " w0arp "), "W0ARP")
        XCTAssertEqual(BBSTrust.entry(from: "n0call-7"), "N0CALL-7")
        XCTAssertNil(BBSTrust.entry(from: ""))
        XCTAssertNil(BBSTrust.entry(from: "W0ARP-16"), "SSIDs run 0 to 15")
        XCTAssertNil(BBSTrust.entry(from: "not a call"))
    }

    func testTheSummaryStartsWithTheOperator() {
        XCTAssertEqual(BBSTrust.summary(station: "K0EPI-4", list: []), "K0EPI (you)")
        XCTAssertEqual(BBSTrust.summary(station: "K0EPI", list: ["W0ARP", "N0CALL-7"]), "K0EPI (you), W0ARP, N0CALL-7")
    }
}
