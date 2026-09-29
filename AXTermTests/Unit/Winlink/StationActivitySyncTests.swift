import XCTest
@testable import AXTerm

/// Sharing observations between an operator's stations.
///
/// The whole design rests on one rule: what another antenna heard may be
/// *read* here, but must never become part of what this station believes.
/// These tests are that rule, written down.
final class StationActivitySyncTests: XCTestCase {

    /// A store that records exactly which side each write landed on, so a
    /// leak from remote into local is a test failure rather than a subtle
    /// wrong number on a screen months later.
    private final class SpyStore: StationActivityStore, @unchecked Sendable {
        var local: [StationActivityPayload] = []
        var remote: [StationActivityPayload] = []

        func localStationActivity() throws -> [StationActivityPayload] { local }
        func saveRemoteStationActivity(_ payloads: [StationActivityPayload]) throws {
            remote.append(contentsOf: payloads)
        }
        func remoteStationActivity() throws -> [StationActivityPayload] { remote }
    }

    private func payload(callsign: String,
                         station: String,
                         device: String,
                         heard: Date = Date(timeIntervalSince1970: 1_000)) -> StationActivityPayload {
        StationActivityPayload(
            callsign: callsign,
            roles: ["Node"],
            firstHeard: heard,
            lastHeard: heard,
            frameCount: 7,
            airtimeSeconds: 3.5,
            provenance: WinlinkSyncProvenance(
                station: station, deviceID: device,
                gridSquare: "DM79", observedAt: heard))
    }

    private func record(_ payload: StationActivityPayload) throws -> WinlinkSyncRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return WinlinkSyncRecord(
            kind: .stationActivity,
            id: StationActivitySyncSource.recordID(payload),
            modifiedAt: payload.lastHeard,
            payload: try encoder.encode(payload))
    }

    // MARK: The rule

    /// Station activity is a measurement, so the policy must not classify it
    /// as ordinary synced state — that is what would let it merge.
    func testStationActivityIsAttributedNotSynced() {
        XCTAssertTrue(WinlinkSyncPolicy.isAttributed(.stationActivity))
        XCTAssertFalse(WinlinkSyncPolicy.syncedKinds.contains(.stationActivity))
    }

    /// It must still cross the wire, though — attributed is not a refusal.
    func testAttributedKindsAreStillReplicated() {
        XCTAssertTrue(WinlinkSyncPolicy.replicatedKinds.contains(.stationActivity))
    }

    /// The measurements that describe this antenna stay put, as before. If
    /// this ever flips, another station's link quality becomes this
    /// station's prediction.
    func testAntennaMeasurementsAreStillNotReplicated() {
        for kind in [WinlinkSyncPolicy.Kind.sessionLog, .gatewayLadder,
                     .stationPreferences, .gridSquare] {
            XCTAssertFalse(WinlinkSyncPolicy.replicatedKinds.contains(kind),
                           "\(kind) must not cross devices")
        }
    }

    /// Every disposition explains itself — the project requires the *why*,
    /// not a label.
    func testTheAttributedDispositionCarriesItsReasoning() {
        let why = WinlinkSyncPolicy.reason(for: .stationActivity)
        XCTAssertFalse(why.isEmpty)
        XCTAssertTrue(why.lowercased().contains("antenna"),
                      "the reason should name the thing that makes it unmergeable")
    }

    // MARK: Applying

    /// Incoming observations land in the remote table and nowhere else.
    func testRemoteObservationsNeverTouchLocalState() throws {
        let store = SpyStore()
        store.local = [payload(callsign: "W0ARP-10", station: "K0EPI-9", device: "ipad")]
        let source = StationActivitySyncSource(store: store, deviceID: "ipad")

        try source.apply([try record(
            payload(callsign: "N0CVL-10", station: "K0EPI-7", device: "mac"))])

        XCTAssertEqual(store.remote.map(\.callsign), ["N0CVL-10"])
        XCTAssertEqual(store.local.map(\.callsign), ["W0ARP-10"],
                       "local observations must be untouched by a sync pass")
    }

    /// A device must not re-import what it published. Without this the
    /// station's own counts would double on the screen built to keep the two
    /// apart.
    func testADeviceIgnoresItsOwnEcho() throws {
        let store = SpyStore()
        let source = StationActivitySyncSource(store: store, deviceID: "mac")
        let applied = try source.apply([try record(
            payload(callsign: "N0CVL-10", station: "K0EPI-7", device: "mac"))])

        XCTAssertEqual(applied, 0)
        XCTAssertTrue(store.remote.isEmpty)
    }

    /// Provenance survives the round trip. It is the only thing separating
    /// "heard here" from "heard there", and it cannot be reconstructed.
    func testProvenanceSurvivesTheRoundTrip() throws {
        let store = SpyStore()
        let source = StationActivitySyncSource(store: store, deviceID: "ipad")
        let sent = payload(callsign: "N0CVL-10", station: "K0EPI-7", device: "mac")

        try source.apply([try record(sent)])

        let landed = try XCTUnwrap(store.remote.first)
        XCTAssertEqual(landed.provenance.station, "K0EPI-7")
        XCTAssertEqual(landed.provenance.deviceID, "mac")
        XCTAssertEqual(landed.provenance.gridSquare, "DM79")
    }

    // MARK: Identity

    /// Two receivers hearing the same station are two observations. Keying
    /// on the callsign alone would let the later arrival overwrite the
    /// earlier, discarding one antenna's view entirely.
    func testTwoReceiversHearingOneStationAreTwoRecords() {
        let fromMac = payload(callsign: "N0CVL-10", station: "K0EPI-7", device: "mac")
        let fromPad = payload(callsign: "N0CVL-10", station: "K0EPI-9", device: "ipad")
        XCTAssertNotEqual(StationActivitySyncSource.recordID(fromMac),
                          StationActivitySyncSource.recordID(fromPad))
    }

    /// Publishing reads the local table only.
    func testPublishingOffersOnlyLocalObservations() throws {
        let store = SpyStore()
        store.local = [payload(callsign: "W0ARP-10", station: "K0EPI-9", device: "ipad")]
        store.remote = [payload(callsign: "N0CVL-10", station: "K0EPI-7", device: "mac")]
        let source = StationActivitySyncSource(store: store, deviceID: "ipad")

        let published = try source.localRecords()
        XCTAssertEqual(published.count, 1)
        XCTAssertTrue(published[0].id.contains("W0ARP-10"))
    }

    /// A corrupt payload is reported, not silently dropped — a sync that
    /// quietly discards data is the failure mode that took longest to find
    /// last time.
    func testAnUnreadablePayloadIsSurfaced() {
        let store = SpyStore()
        let source = StationActivitySyncSource(store: store, deviceID: "ipad")
        let junk = WinlinkSyncRecord(kind: .stationActivity, id: "mac|N0CVL-10",
                                     modifiedAt: Date(), payload: Data([0x00, 0x01]))
        XCTAssertThrowsError(try source.apply([junk]))
    }
}
