import XCTest
@testable import AXTerm

/// Carrying the operator's own details between their devices.
///
/// Written after the fact, because the policy declared these syncable and
/// nothing implemented it — a second device asked for a callsign it could
/// have inherited. The end-to-end case is tested here rather than only the
/// merge rules, since that gap is exactly what the unit tests missed.
final class WinlinkIdentitySyncTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// One device's settings, in memory.
    private final class FakeIdentityStore: WinlinkIdentitySyncSource.Store, @unchecked Sendable {
        private let lock = NSLock()
        private var payload: WinlinkIdentityPayload

        init(_ payload: WinlinkIdentityPayload) { self.payload = payload }

        func read() -> WinlinkIdentityPayload {
            lock.lock(); defer { lock.unlock() }
            return payload
        }

        func apply(_ new: WinlinkIdentityPayload) {
            lock.lock(); defer { lock.unlock() }
            payload = new
        }
    }

    private func engine(_ store: FakeIdentityStore,
                        _ transport: WinlinkInMemorySyncTransport) -> WinlinkSyncEngine {
        WinlinkSyncEngine(
            transport: transport,
            sources: WinlinkIdentitySyncSource.sources(store: store),
            tokenStore: WinlinkMemoryTokenStore())
    }

    // MARK: - The thing that was broken

    /// The whole point: a configured Mac and a fresh iPad, and the iPad ends
    /// up knowing who the operator is.
    func testAConfiguredDeviceCarriesTheCallsignToAFreshOne() async throws {
        let transport = WinlinkInMemorySyncTransport()
        let mac = FakeIdentityStore(WinlinkIdentityPayload(
            callsignBase: "K0EPI", realName: "Ross Wardrup", updatedAt: t(100)))
        let iPad = FakeIdentityStore(WinlinkIdentityPayload(updatedAt: t(0)))

        try await engine(mac, transport).sync()
        try await engine(iPad, transport).sync()

        XCTAssertEqual(iPad.read().callsignBase, "K0EPI")
        XCTAssertEqual(iPad.read().realName, "Ross Wardrup")
    }

    /// The ICS details travel too — retyping an address per device is the
    /// friction this exists to remove.
    func testTheOperatorProfileCarriesAcross() async throws {
        let transport = WinlinkInMemorySyncTransport()
        let mac = FakeIdentityStore(WinlinkIdentityPayload(
            callsignBase: "K0EPI", realName: "Ross Wardrup",
            organization: "ARES District 3", phone: "555-0100",
            city: "Denver", state: "CO", updatedAt: t(100)))
        let iPad = FakeIdentityStore(WinlinkIdentityPayload(updatedAt: t(0)))

        try await engine(mac, transport).sync()
        try await engine(iPad, transport).sync()

        let result = iPad.read()
        XCTAssertEqual(result.organization, "ARES District 3")
        XCTAssertEqual(result.phone, "555-0100")
        XCTAssertEqual(result.city, "Denver")
        XCTAssertEqual(result.state, "CO")
    }

    // MARK: - What must not travel

    /// The SSID is the station, not the operator. If it crossed, both devices
    /// would answer to one address — the collision `StationIdentityMonitor`
    /// exists to detect. The record carries the licence only.
    func testTheSSIDIsStrippedFromWhatIsPublished() async throws {
        // Seeded *with* an SSID on purpose. Stripping happens in the live
        // store too, but relying on that alone would mean the guarantee
        // depended on which store was plugged in.
        let store = FakeIdentityStore(WinlinkIdentityPayload(
            callsignBase: "K0EPI-7", updatedAt: t(100)))
        let source = WinlinkIdentitySyncSource(kind: .callsignBase, store: store)

        let records = try await source.localRecords()
        let text = try XCTUnwrap(String(data: records[0].payload, encoding: .utf8))

        XCTAssertTrue(text.contains("K0EPI"), text)
        XCTAssertFalse(text.contains("K0EPI-7"), "an SSID must not be published")
    }

    /// And an SSID that somehow arrives is discarded rather than adopted.
    func testAnArrivingSSIDIsDiscarded() {
        let merged = WinlinkIdentityPayload.merge(
            local: WinlinkIdentityPayload(updatedAt: t(0)),
            remote: WinlinkIdentityPayload(callsignBase: "K0EPI-7", updatedAt: t(100)),
            for: .callsignBase)
        XCTAssertEqual(merged.callsignBase, "K0EPI")
    }

    /// The callsign record carries no address, and the profile record carries
    /// no callsign — so one being newer cannot drag the other backwards.
    func testTheTwoRecordsDoNotOverlap() async throws {
        let store = FakeIdentityStore(WinlinkIdentityPayload(
            callsignBase: "K0EPI", realName: "Ross Wardrup", updatedAt: t(100)))

        let callsignRecord = try await WinlinkIdentitySyncSource(kind: .callsignBase, store: store)
            .localRecords()[0]
        let profileRecord = try await WinlinkIdentitySyncSource(kind: .operatorProfile, store: store)
            .localRecords()[0]

        let callsignText = try XCTUnwrap(String(data: callsignRecord.payload, encoding: .utf8))
        let profileText = try XCTUnwrap(String(data: profileRecord.payload, encoding: .utf8))

        XCTAssertFalse(callsignText.contains("Ross Wardrup"))
        XCTAssertFalse(profileText.contains("K0EPI"))
    }

    // MARK: - Not destroying anything

    /// An unconfigured device publishes nothing. Otherwise a fresh iPad's
    /// empty record would race the Mac's and blank it.
    func testAnUnconfiguredDevicePublishesNothing() async throws {
        let empty = FakeIdentityStore(WinlinkIdentityPayload(updatedAt: t(0)))
        let callsign = try await WinlinkIdentitySyncSource(kind: .callsignBase, store: empty)
            .localRecords()
        let profile = try await WinlinkIdentitySyncSource(kind: .operatorProfile, store: empty)
            .localRecords()
        XCTAssertTrue(callsign.isEmpty)
        XCTAssertTrue(profile.isEmpty)
    }

    /// A blank never beats a value. A device mid-edit can briefly hold an
    /// empty field, and letting that win would wipe the operator's details
    /// everywhere they own a radio.
    func testABlankNeverOverwritesAValue() {
        let merged = WinlinkIdentityPayload.merge(
            local: WinlinkIdentityPayload(realName: "Ross Wardrup", updatedAt: t(0)),
            remote: WinlinkIdentityPayload(realName: "", updatedAt: t(999)),
            for: .operatorProfile)
        XCTAssertEqual(merged.realName, "Ross Wardrup")
    }

    /// A real edit on a newer device does win.
    func testANewerEditWins() {
        let merged = WinlinkIdentityPayload.merge(
            local: WinlinkIdentityPayload(realName: "Old Name", updatedAt: t(0)),
            remote: WinlinkIdentityPayload(realName: "New Name", updatedAt: t(100)),
            for: .operatorProfile)
        XCTAssertEqual(merged.realName, "New Name")
    }

    func testAnOlderEditDoesNotWin() {
        let merged = WinlinkIdentityPayload.merge(
            local: WinlinkIdentityPayload(realName: "Current", updatedAt: t(100)),
            remote: WinlinkIdentityPayload(realName: "Stale", updatedAt: t(0)),
            for: .operatorProfile)
        XCTAssertEqual(merged.realName, "Current")
    }

    // MARK: - Convergence

    /// Syncing repeatedly must settle rather than the two devices trading
    /// updates forever.
    func testRepeatedSyncsConverge() async throws {
        let transport = WinlinkInMemorySyncTransport()
        let mac = FakeIdentityStore(WinlinkIdentityPayload(
            callsignBase: "K0EPI", realName: "Ross Wardrup", updatedAt: t(100)))
        let iPad = FakeIdentityStore(WinlinkIdentityPayload(updatedAt: t(0)))

        let macEngine = engine(mac, transport)
        let iPadEngine = engine(iPad, transport)

        for _ in 0..<3 {
            try await macEngine.sync()
            try await iPadEngine.sync()
        }

        XCTAssertEqual(mac.read().callsignBase, iPad.read().callsignBase)
        XCTAssertEqual(mac.read().realName, iPad.read().realName)
    }

    /// Applying a record that changes nothing must not count as a change, or
    /// every pass reports work it did not do.
    func testApplyingAnIdenticalRecordChangesNothing() async throws {
        let transport = WinlinkInMemorySyncTransport()
        let mac = FakeIdentityStore(WinlinkIdentityPayload(
            callsignBase: "K0EPI", updatedAt: t(100)))

        try await engine(mac, transport).sync()
        let second = try await engine(mac, transport).sync()

        XCTAssertEqual(second.applied, 0)
    }

    /// One corrupt record must not wedge the pass.
    func testAnUnreadablePayloadIsReportedNotFatal() async throws {
        let transport = WinlinkInMemorySyncTransport()
        try await transport.push([WinlinkSyncRecord(
            kind: .callsignBase, id: WinlinkIdentitySyncSource.recordID,
            modifiedAt: t(0), payload: Data("not json".utf8))])

        let store = FakeIdentityStore(WinlinkIdentityPayload(updatedAt: t(0)))
        let report = try await engine(store, transport).sync()

        XCTAssertEqual(report.unreadable, 1)
        XCTAssertEqual(store.read().callsignBase, "")
    }

    // MARK: - The live store

    /// These exercise the real settings objects rather than a fake, because
    /// the SSID-preservation rule lives in `LiveIdentityStore.apply` and a
    /// fake store would test nothing but the fake.
    @MainActor
    private func liveStore(callsign: String) async -> (LiveIdentityStore, AppSettingsStore, StationProfile, UserDefaults) {
        let suite = "identity-sync-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettingsStore(defaults: defaults)
        let profile = StationProfile(defaults: defaults)
        settings.myCallsign = callsign
        return (LiveIdentityStore(settings: settings, profile: profile, defaults: defaults),
                settings, profile, defaults)
    }

    /// The one that matters. An iPad running as K0EPI-9 that accepts the
    /// Mac's callsign must stay -9: adopting the whole thing would put two
    /// stations on one address, which is the collision
    /// `StationIdentityMonitor` exists to detect and `StationIdentityLease`
    /// exists to prevent.
    @MainActor
    func testApplyingACallsignKeepsThisDevicesSSID() async {
        let (store, settings, _, _) = await liveStore(callsign: "K0EPI-9")

        await store.apply(WinlinkIdentityPayload(callsignBase: "K0EPI", updatedAt: t(100)))

        XCTAssertEqual(settings.myCallsign, "K0EPI-9")
    }

    /// A device with no SSID stays without one — the rule preserves what is
    /// there, it does not invent a station address.
    @MainActor
    func testApplyingACallsignToADeviceWithNoSSIDAddsNone() async {
        let (store, settings, _, _) = await liveStore(callsign: "")

        await store.apply(WinlinkIdentityPayload(callsignBase: "K0EPI", updatedAt: t(100)))

        XCTAssertEqual(settings.myCallsign, "K0EPI")
    }

    /// A corrected licence still lands; only the SSID half is protected.
    @MainActor
    func testACorrectedCallsignIsAdoptedUnderTheSameSSID() async {
        let (store, settings, _, _) = await liveStore(callsign: "K0OLD-9")

        await store.apply(WinlinkIdentityPayload(callsignBase: "K0EPI", updatedAt: t(100)))

        XCTAssertEqual(settings.myCallsign, "K0EPI-9")
    }

    /// And the live store never publishes its SSID either.
    @MainActor
    func testTheLiveStoreReadsTheLicenceWithoutTheSSID() async {
        let (store, _, _, _) = await liveStore(callsign: "K0EPI-9")
        let read = await store.read()
        XCTAssertEqual(read.callsignBase, "K0EPI")
    }

    /// An empty record must not blank a configured device — the guard in
    /// `apply` is what stops a fresh iPad wiping the Mac.
    @MainActor
    func testApplyingAnEmptyPayloadLeavesTheDeviceAlone() async {
        let (store, settings, profile, _) = await liveStore(callsign: "K0EPI-9")
        profile.realName = "Ross Wardrup"

        await store.apply(WinlinkIdentityPayload(updatedAt: t(100)))

        XCTAssertEqual(settings.myCallsign, "K0EPI-9")
        XCTAssertEqual(profile.realName, "Ross Wardrup")
    }

    /// The profile fields land where the forms read them from.
    @MainActor
    func testApplyingAProfileWritesTheFormFields() async {
        let (store, _, profile, _) = await liveStore(callsign: "K0EPI-9")

        await store.apply(WinlinkIdentityPayload(
            realName: "Ross Wardrup", positionTitle: "EC",
            organization: "ARES District 3", city: "Denver", state: "CO",
            updatedAt: t(100)))

        XCTAssertEqual(profile.realName, "Ross Wardrup")
        XCTAssertEqual(profile.nameWithTitle, "Ross Wardrup, EC")
        XCTAssertEqual(profile.organization, "ARES District 3")
        XCTAssertEqual(profile.city, "Denver")
    }

    /// A device that has never been edited must not claim to be newer than
    /// one that has, or an unconfigured iPad would outrank the Mac.
    @MainActor
    func testAnUneditedDeviceCarriesTheOldestPossibleStamp() async {
        let (store, settings, _, _) = await liveStore(callsign: "K0EPI-9")
        _ = settings

        let unedited = await store.read().updatedAt
        store.stampLocalEdit(at: t(100))
        let stamped = await store.read().updatedAt

        XCTAssertLessThan(unedited, t(100))
        XCTAssertEqual(stamped, t(100))
    }

    /// Round trip through the real store: what one device publishes is what
    /// the other adopts, SSIDs intact on both sides.
    @MainActor
    func testTwoLiveDevicesExchangeIdentityAndKeepTheirOwnSSIDs() async throws {
        let transport = WinlinkInMemorySyncTransport()
        let (mac, macSettings, macProfile, _) = await liveStore(callsign: "K0EPI-10")
        let (iPad, iPadSettings, iPadProfile, _) = await liveStore(callsign: "K0EPI-9")

        macProfile.realName = "Ross Wardrup"
        macProfile.city = "Denver"
        mac.stampLocalEdit(at: t(100))

        try await WinlinkSyncEngine(
            transport: transport,
            sources: WinlinkIdentitySyncSource.sources(store: mac),
            tokenStore: WinlinkMemoryTokenStore()).sync()
        try await WinlinkSyncEngine(
            transport: transport,
            sources: WinlinkIdentitySyncSource.sources(store: iPad),
            tokenStore: WinlinkMemoryTokenStore()).sync()

        XCTAssertEqual(iPadProfile.realName, "Ross Wardrup")
        XCTAssertEqual(iPadProfile.city, "Denver")
        XCTAssertEqual(iPadSettings.myCallsign, "K0EPI-9", "the iPad keeps its own station address")
        XCTAssertEqual(macSettings.myCallsign, "K0EPI-10", "and the Mac keeps its own")
    }
}
