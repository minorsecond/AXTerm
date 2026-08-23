import XCTest
import GRDB
@testable import AXTerm

@MainActor
final class WinlinkViewModelTests: XCTestCase {

    private func makeStore() throws -> SQLiteWinlinkStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteWinlinkStore(dbQueue: queue)
    }

    private func makeMessage(mid: String, subject: String = "VM test", from: String = "W1AW") -> WinlinkB2Message {
        WinlinkB2Message(
            mid: mid,
            date: WinlinkB2Message.dateFormatter.date(from: "2026/08/23 12:00")!,
            type: .privateMessage,
            from: from,
            to: ["K0EPI"],
            cc: [],
            subject: subject,
            mbo: from,
            body: Data("Line one.\r\nLine two.\r\n".utf8),
            attachments: [])
    }

    private func makeSettings() -> WinlinkSettings {
        let defaults = UserDefaults(suiteName: "WinlinkVMTests-\(UUID().uuidString)")!
        return WinlinkSettings(defaults: defaults, keychain: KeychainStore(service: "test-\(UUID().uuidString)"))
    }

    // MARK: - Mailbox

    func testMailboxStartsInInboxAndTracksUnread() async throws {
        let store = try makeStore()
        try store.saveInbound(makeMessage(mid: "VMINBOUND001"))
        let vm = WinlinkMailboxViewModel(store: store, myCallsign: { "K0EPI" })

        XCTAssertEqual(vm.selectedFolderID, try store.folderID(for: .inbox))
        XCTAssertEqual(vm.filteredMessages.map(\.mid), ["VMINBOUND001"])
        XCTAssertEqual(vm.unreadCount, 1)

        // Selecting a message marks it read.
        vm.selectedMID = "VMINBOUND001"
        XCTAssertEqual(vm.selectedMessage?.message.mid, "VMINBOUND001")
        XCTAssertEqual(vm.unreadCount, 0)
    }

    func testMailboxSearchFilters() async throws {
        let store = try makeStore()
        try store.saveInbound(makeMessage(mid: "VMSEARCH0001", subject: "Weather report"))
        try store.saveInbound(makeMessage(mid: "VMSEARCH0002", subject: "Net schedule"))
        let vm = WinlinkMailboxViewModel(store: store, myCallsign: { "K0EPI" })

        vm.searchText = "weather"
        XCTAssertEqual(vm.filteredMessages.map(\.mid), ["VMSEARCH0001"])
        vm.searchText = ""
        XCTAssertEqual(vm.filteredMessages.count, 2)
    }

    func testReplyDraftPrefills() async throws {
        let store = try makeStore()
        var original = makeMessage(mid: "VMREPLY00001", subject: "Question")
        original.cc = ["N0XYZ"]
        try store.saveInbound(original)
        let vm = WinlinkMailboxViewModel(store: store, myCallsign: { "K0EPI" })
        vm.selectedMID = "VMREPLY00001"
        let stored = try XCTUnwrap(vm.selectedMessage)

        let reply = vm.replyDraft(to: stored, replyAll: false)
        XCTAssertEqual(reply.to, ["W1AW"])
        XCTAssertEqual(reply.subject, "Re: Question")
        XCTAssertEqual(reply.from, "K0EPI")
        let bodyText = String(data: reply.body, encoding: .isoLatin1)!
        XCTAssertTrue(bodyText.contains("> Line one."), bodyText)

        let replyAll = vm.replyDraft(to: stored, replyAll: true)
        XCTAssertEqual(replyAll.cc, ["N0XYZ"], "reply-all keeps other recipients, drops me and the sender")
    }

    func testForwardDraftCarriesAttachments() async throws {
        let store = try makeStore()
        var original = makeMessage(mid: "VMFWD000001")
        original.attachments = [.init(name: "map.png", data: Data([1, 2, 3]))]
        try store.saveInbound(original)
        let vm = WinlinkMailboxViewModel(store: store, myCallsign: { "K0EPI" })
        vm.selectedMID = "VMFWD000001"

        let forward = vm.forwardDraft(of: vm.selectedMessage!)
        XCTAssertEqual(forward.subject, "Fw: VM test")
        XCTAssertEqual(forward.attachments.map(\.name), ["map.png"])
        XCTAssertTrue(forward.to.isEmpty)
    }

    // MARK: - Compose

    func testComposeAddressNormalization() async {
        XCTAssertEqual(WinlinkComposeViewModel.normalizeAddress("k0epi"), "K0EPI")
        XCTAssertEqual(WinlinkComposeViewModel.normalizeAddress("KE7XO-10"), "KE7XO-10")
        XCTAssertEqual(WinlinkComposeViewModel.normalizeAddress("someone@example.com"), "SMTP:someone@example.com")
        XCTAssertEqual(WinlinkComposeViewModel.normalizeAddress("SMTP:a@b.co"), "SMTP:a@b.co")
        XCTAssertNil(WinlinkComposeViewModel.normalizeAddress("not a callsign!"))
        XCTAssertNil(WinlinkComposeViewModel.normalizeAddress("SMTP:noatsign"))
    }

    func testComposeQueueHappyPath() async throws {
        let store = try makeStore()
        let vm = WinlinkComposeViewModel(store: store, myCallsign: "K0EPI")
        vm.toText = "W1AW, someone@example.com"
        vm.subject = "Hello"
        vm.bodyText = "First line\nSecond line"

        let mid = try XCTUnwrap(vm.queueForSending())
        let queued = try store.queuedOutboundMessages()
        XCTAssertEqual(queued.map(\.mid), [mid])
        XCTAssertEqual(queued[0].to, ["W1AW", "SMTP:someone@example.com"])
        // LF input became CRLF wire form.
        XCTAssertEqual(String(data: queued[0].body, encoding: .isoLatin1), "First line\r\nSecond line")
    }

    func testComposeRejectsInvalidAddressAndEmptyTo() async throws {
        let store = try makeStore()
        let vm = WinlinkComposeViewModel(store: store, myCallsign: "K0EPI")
        vm.subject = "x"

        XCTAssertNil(vm.queueForSending())
        XCTAssertNotNil(vm.validationError)

        vm.toText = "!!bad!!"
        XCTAssertNil(vm.queueForSending())
        XCTAssertTrue(vm.validationError!.contains("Invalid address"), vm.validationError!)
    }

    func testComposeEnforcesSizeBudget() async throws {
        let store = try makeStore()
        let vm = WinlinkComposeViewModel(store: store, myCallsign: "K0EPI")
        vm.toText = "W1AW"
        vm.addAttachment(name: "big.bin", data: Data(repeating: 0, count: 121 * 1024))

        XCTAssertTrue(vm.isOverBudget)
        XCTAssertNil(vm.queueForSending())
        XCTAssertTrue(vm.validationError!.contains("limit"), vm.validationError!)
    }

    func testComposeRejectsNonLatin1Body() async throws {
        let store = try makeStore()
        let vm = WinlinkComposeViewModel(store: store, myCallsign: "K0EPI")
        vm.toText = "W1AW"
        vm.bodyText = "emoji 🚀 not allowed"
        XCTAssertNil(vm.queueForSending())
        XCTAssertTrue(vm.validationError!.contains("ISO-8859-1"), vm.validationError!)
    }

    // MARK: - Stations

    private final class FakeCMSClient: CMSClienting, @unchecked Sendable {
        var stations: [WinlinkRMSStationRecord] = []
        var catalog: [WinlinkCatalogItemRecord] = []
        var error: Error?
        private(set) var proximityCalls = 0

        func gatewayProximity(gridSquare: String, maxDistanceMiles: Int, historyHours: Int) async throws -> [WinlinkRMSStationRecord] {
            proximityCalls += 1
            if let error { throw error }
            return stations
        }

        func inquiriesCatalog() async throws -> [WinlinkCatalogItemRecord] {
            if let error { throw error }
            return catalog
        }
    }

    private func makeStation(callsign: String, distance: Double) -> WinlinkRMSStationRecord {
        WinlinkRMSStationRecord(
            callsign: callsign, gridSquare: "DM79", frequencyHz: 145_050_000,
            modeName: "Packet", baud: "1200", serviceCode: "PUBLIC",
            distanceMiles: distance, headingDegrees: 0, lastSeenAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 5_000))
    }

    func testStationsRefreshBlockedWithoutGrid() async throws {
        let store = try makeStore()
        let client = FakeCMSClient()
        let settings = makeSettings()
        let vm = RMSStationsViewModel(store: store, makeClient: { client }, settings: settings)

        XCTAssertNotNil(vm.refreshBlocker)
        await vm.refresh()
        XCTAssertEqual(client.proximityCalls, 0, "no API call without a grid square")
        XCTAssertNotNil(vm.errorText)
    }

    func testStationsRefreshCachesResults() async throws {
        let store = try makeStore()
        let client = FakeCMSClient()
        client.stations = [makeStation(callsign: "KE7XO-10", distance: 12)]
        let settings = makeSettings()
        settings.gridSquare = "DM79lr"
        let vm = RMSStationsViewModel(store: store, makeClient: { client }, settings: settings)

        await vm.refresh()
        XCTAssertNil(vm.errorText)
        XCTAssertEqual(vm.stations.map(\.callsign), ["KE7XO-10"])
        // Cache survives a new view model (offline start).
        let vm2 = RMSStationsViewModel(store: store, makeClient: { FakeCMSClient() }, settings: settings)
        XCTAssertEqual(vm2.stations.map(\.callsign), ["KE7XO-10"])
    }

    func testSetAsGatewayPersists() async throws {
        let store = try makeStore()
        let settings = makeSettings()
        let vm = RMSStationsViewModel(store: store, makeClient: { FakeCMSClient() }, settings: settings)
        vm.setAsGateway(makeStation(callsign: "KE7XO-10", distance: 12))
        XCTAssertEqual(settings.gatewayCallsign, "KE7XO-10")
        XCTAssertEqual(vm.currentGateway, "KE7XO-10")
    }

    // MARK: - Catalog

    private func makeCatalogItem(id: String, category: String, size: Int = 1000) -> WinlinkCatalogItemRecord {
        WinlinkCatalogItemRecord(
            inquiryId: id, category: category, subject: "Subject \(id)", url: "",
            lifetimeDays: 1, sizeEstimate: size, enabled: true,
            fetchedAt: Date(timeIntervalSince1970: 6_000))
    }

    func testCatalogGroupsByCategory() async throws {
        let store = try makeStore()
        let client = FakeCMSClient()
        client.catalog = [
            makeCatalogItem(id: "WX_CONUS", category: "Weather"),
            makeCatalogItem(id: "WX_CARIB", category: "Weather"),
            makeCatalogItem(id: "NEWS_TOP", category: "News"),
        ]
        let vm = WinlinkCatalogViewModel(store: store, makeClient: { client })
        await vm.refresh()

        XCTAssertEqual(vm.groups.map(\.category), ["News", "Weather"])
        XCTAssertEqual(vm.groups[1].items.map(\.inquiryId), ["WX_CARIB", "WX_CONUS"])
    }

    func testCatalogRequestMessageExactFormat() async throws {
        let store = try makeStore()
        let client = FakeCMSClient()
        client.catalog = [
            makeCatalogItem(id: "WX_CONUS", category: "Weather", size: 4000),
            makeCatalogItem(id: "NEWS_TOP", category: "News", size: 2500),
        ]
        let vm = WinlinkCatalogViewModel(store: store, makeClient: { client })
        await vm.refresh()

        vm.selection = ["WX_CONUS", "NEWS_TOP"]
        XCTAssertEqual(vm.selectedSizeEstimate, 6500)

        let message = try XCTUnwrap(vm.buildRequestMessage(myCallsign: "K0EPI"))
        XCTAssertEqual(message.to, ["INQUIRY"])
        XCTAssertEqual(message.subject, "REQUEST")
        XCTAssertEqual(message.type, .inquiry)
        // One InquiryId per CRLF line, catalog order (grouped by category).
        XCTAssertEqual(String(data: message.body, encoding: .isoLatin1), "NEWS_TOP\r\nWX_CONUS\r\n")
    }

    func testCatalogQueueRequestLandsInOutbox() async throws {
        let store = try makeStore()
        let client = FakeCMSClient()
        client.catalog = [makeCatalogItem(id: "WX_CONUS", category: "Weather")]
        let vm = WinlinkCatalogViewModel(store: store, makeClient: { client })
        await vm.refresh()
        vm.selection = ["WX_CONUS"]

        let mid = try XCTUnwrap(vm.queueRequest(myCallsign: "K0EPI"))
        let queued = try store.queuedOutboundMessages()
        XCTAssertEqual(queued.map(\.mid), [mid])
        XCTAssertTrue(vm.selection.isEmpty, "selection clears after queueing")
    }

    func testCatalogQueueWithoutSelectionErrors() async throws {
        let store = try makeStore()
        let vm = WinlinkCatalogViewModel(store: store, makeClient: { FakeCMSClient() })
        XCTAssertNil(vm.queueRequest(myCallsign: "K0EPI"))
        XCTAssertNotNil(vm.errorText)
    }

    // MARK: - Keychain

    func testKeychainRoundTrip() async {
        let keychain = KeychainStore(service: "com.axterm.tests.\(UUID().uuidString)")
        XCTAssertNil(keychain.string(account: "pw"))
        XCTAssertTrue(keychain.setString("secret1", account: "pw"))
        XCTAssertEqual(keychain.string(account: "pw"), "secret1")
        XCTAssertTrue(keychain.setString("secret2", account: "pw"), "update path")
        XCTAssertEqual(keychain.string(account: "pw"), "secret2")
        XCTAssertTrue(keychain.remove(account: "pw"))
        XCTAssertNil(keychain.string(account: "pw"))
    }
}
