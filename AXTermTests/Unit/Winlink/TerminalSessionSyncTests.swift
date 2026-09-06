import XCTest
@testable import AXTerm

/// Seeing what the operator's other stations connected to.
///
/// A transcript is what was said over the air, not a measurement of the
/// air — so unlike a Winlink session log it may travel. But it travelled
/// from a different radio in a different place, and nothing about it may be
/// mistaken for this device's own history. These tests are that rule: what
/// crosses, what stays, and how the origin is stamped on every record.
final class TerminalSessionSyncTests: XCTestCase {

    /// Records which side each write landed on. A remote session appearing
    /// in `local` is the leak the whole design exists to prevent.
    private final class SpyStore: TerminalSessionReplicationStore, @unchecked Sendable {
        var local: [TerminalSession] = []
        var remote: [TerminalSessionPayload] = []

        func localSessionsForPublication(endedSince: Date) throws -> [TerminalSession] {
            local.filter { ($0.endedAt ?? .distantFuture) >= endedSince && $0.outcome != .live }
        }
        func saveRemoteSessions(_ payloads: [TerminalSessionPayload]) throws {
            remote.append(contentsOf: payloads)
        }
        func remoteSessions(limit: Int) throws -> [TerminalSessionPayload] {
            Array(remote.prefix(limit))
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_756_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func session(_ remote: String,
                         endedAt: Date? = nil,
                         outcome: TerminalSession.Outcome = .closed,
                         transcript: String = "K0EPI-7: hello\nN0CVL-10: hi",
                         tags: [String] = [],
                         note: String? = nil) -> TerminalSession {
        TerminalSession(remote: remote, via: ["DRLNOD"],
                        startedAt: t(-300), endedAt: endedAt ?? t(0),
                        outcome: outcome, framesSent: 3, framesReceived: 4,
                        bytesSent: 30, bytesReceived: 40,
                        transcript: transcript, tags: tags, note: note)
    }

    private func source(_ store: SpyStore, device: String,
                        deviceName: String? = "Ross\u{2019}s Mac",
                        station: String = "K0EPI-7",
                        now: Date? = nil) -> TerminalSessionSyncSource {
        let clock = now ?? t(60)
        return TerminalSessionSyncSource(
            store: store, deviceID: device, deviceName: deviceName,
            station: { station }, gridSquare: { "DM79" }, now: { clock })
    }

    private func payload(_ session: TerminalSession, station: String = "K0EPI-1",
                         device: String = "ipad", deviceName: String? = "iPad") -> TerminalSessionPayload {
        TerminalSessionPayload(
            session: session,
            provenance: WinlinkSyncProvenance(
                station: station, deviceID: device, gridSquare: "DM79",
                observedAt: session.endedAt ?? session.startedAt),
            deviceName: deviceName)
    }

    private func record(_ payload: TerminalSessionPayload) throws -> WinlinkSyncRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return WinlinkSyncRecord(
            kind: .terminalSession,
            id: TerminalSessionSyncSource.recordID(payload),
            modifiedAt: payload.endedAt,
            payload: try encoder.encode(payload))
    }

    // MARK: The rule

    /// A transcript is attributed, never merged: the policy must say so, or
    /// the engine would treat it as ordinary synced state.
    func testTerminalSessionsAreAttributedNotSynced() {
        XCTAssertTrue(WinlinkSyncPolicy.isAttributed(.terminalSession))
        XCTAssertFalse(WinlinkSyncPolicy.syncedKinds.contains(.terminalSession))
        XCTAssertTrue(WinlinkSyncPolicy.replicatedKinds.contains(.terminalSession))
    }

    /// The reason has to draw the line against `sessionLog`, which stays
    /// home for being a measurement. A reader who sees one travel and the
    /// other refused deserves the distinction in the source.
    func testTheDispositionExplainsWhyATranscriptMayTravel() {
        let reason = WinlinkSyncPolicy.reason(for: .terminalSession).lowercased()
        XCTAssertTrue(reason.contains("said") || reason.contains("transcript"), reason)
        XCTAssertTrue(reason.contains("measure"), reason)
    }

    /// Applying another device's sessions fills the remote side only.
    func testRemoteSessionsNeverTouchLocalState() throws {
        let store = SpyStore()
        store.local = [session("N0CVL-10")]
        let source = source(store, device: "mac")

        let applied = try source.apply([try record(payload(session("KB5YZB-7")))])

        XCTAssertEqual(applied, 1)
        XCTAssertEqual(store.remote.map(\.remote), ["KB5YZB-7"])
        XCTAssertEqual(store.local.map(\.remote), ["N0CVL-10"], "the local table must be untouched")
    }

    /// A device's own published records come back to it on the next pull.
    /// They must not be filed as another device's.
    func testADeviceIgnoresItsOwnEcho() throws {
        let store = SpyStore()
        let source = source(store, device: "mac")

        let applied = try source.apply([
            try record(payload(session("KB5YZB-7"), device: "mac"))])

        XCTAssertEqual(applied, 0)
        XCTAssertTrue(store.remote.isEmpty)
    }

    /// Where a session came from — station, installation, and the name a
    /// person would recognise — survives the wire intact. The name is what
    /// the History screen shows, so losing it would leave a row that says
    /// only "somewhere else".
    func testProvenanceAndDeviceNameSurviveTheRoundTrip() throws {
        let store = SpyStore()
        try source(store, device: "mac").apply([
            try record(payload(session("KB5YZB-7"), station: "K0EPI-1",
                               device: "ipad", deviceName: "Ross\u{2019}s iPad"))])

        let back = try XCTUnwrap(store.remote.first)
        XCTAssertEqual(back.provenance.station, "K0EPI-1")
        XCTAssertEqual(back.provenance.deviceID, "ipad")
        XCTAssertEqual(back.provenance.gridSquare, "DM79")
        XCTAssertEqual(back.deviceName, "Ross\u{2019}s iPad")
        XCTAssertEqual(back.remote, "KB5YZB-7")
        XCTAssertEqual(back.via, ["DRLNOD"])
        XCTAssertEqual(back.transcript, "K0EPI-7: hello\nN0CVL-10: hi")
        XCTAssertEqual(back.framesReceived, 4)
        XCTAssertEqual(back.bytesSent, 30)
    }

    /// The payload turns back into a session the History screen can render
    /// with the same row it uses for local ones — but never with a live
    /// outcome or a note, which belong to the device that made them.
    func testAPayloadRendersAsASession() throws {
        let original = session("KB5YZB-7", tags: ["net"], note: "checked in")
        let rendered = payload(original).session

        XCTAssertEqual(rendered.id, original.id)
        XCTAssertEqual(rendered.remote, "KB5YZB-7")
        XCTAssertEqual(rendered.via, ["DRLNOD"])
        XCTAssertEqual(rendered.startedAt, original.startedAt)
        XCTAssertEqual(rendered.endedAt, original.endedAt)
        XCTAssertEqual(rendered.outcome, .closed)
        XCTAssertEqual(rendered.transcript, original.transcript)
        XCTAssertEqual(rendered.tags, [], "tags are this device's annotation and stay home")
        XCTAssertNil(rendered.note, "a note is this device's annotation and stays home")
    }

    // MARK: What is published

    /// Only what the operator's other device has actually finished. A live
    /// session is rewritten when it ends; publishing it early would push a
    /// half transcript whose final version the push ledger then suppresses,
    /// because nothing about its identity changed.
    func testOnlyEndedSessionsArePublished() throws {
        let store = SpyStore()
        store.local = [
            session("N0CVL-10"),
            session("KB5YZB-7", endedAt: nil, outcome: .live),
        ]

        let ids = try source(store, device: "mac").localRecords().map(\.id)

        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(ids[0].hasSuffix(store.local[0].id.uuidString), ids[0])
    }

    /// Publication is windowed like station activity: the last week. A
    /// year of history is the local store's job, not iCloud's.
    func testPublicationIsWindowedToRecentSessions() throws {
        let store = SpyStore()
        store.local = [
            session("N0CVL-10", endedAt: t(0)),
            session("W0ARP-10", endedAt: t(-TerminalSessionSyncSource.window - 60)),
        ]

        let published = try source(store, device: "mac", now: t(0)).localRecords()

        XCTAssertEqual(published.count, 1)
    }

    /// A record identifies the session and the device that made it, so two
    /// devices can never overwrite each other and one device's history is
    /// one prefix.
    func testRecordIDsCarryTheDevice() throws {
        let one = session("N0CVL-10")
        let fromMac = payload(one, device: "mac")
        let fromPad = payload(one, device: "ipad")

        XCTAssertNotEqual(TerminalSessionSyncSource.recordID(fromMac),
                          TerminalSessionSyncSource.recordID(fromPad))
        XCTAssertTrue(TerminalSessionSyncSource.recordID(fromMac).hasPrefix("mac|"))
    }

    /// The published record says where it came from — this station, this
    /// installation, this device's name — and is dated by when the session
    /// ended, which is the one date that changes exactly once.
    func testPublishedRecordsAreStampedWithOrigin() throws {
        let store = SpyStore()
        store.local = [session("N0CVL-10")]

        let record = try XCTUnwrap(try source(store, device: "mac").localRecords().first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(TerminalSessionPayload.self, from: record.payload)

        XCTAssertEqual(record.kind, .terminalSession)
        XCTAssertEqual(record.modifiedAt, t(0))
        XCTAssertEqual(payload.provenance.station, "K0EPI-7")
        XCTAssertEqual(payload.provenance.deviceID, "mac")
        XCTAssertEqual(payload.provenance.gridSquare, "DM79")
        XCTAssertEqual(payload.deviceName, "Ross\u{2019}s Mac")
    }

    /// Tags and notes are how the operator annotates history on one device.
    /// They do not go on the wire: a note about a session is not the
    /// session, and an annotation made on the Mac editing itself onto the
    /// iPad's copy would be two devices arguing over one sentence.
    func testAnnotationsStayOnTheDeviceThatMadeThem() throws {
        let store = SpyStore()
        store.local = [session("N0CVL-10", tags: ["net", "ares"], note: "checked in")]

        let record = try XCTUnwrap(try source(store, device: "mac").localRecords().first)
        let json = String(decoding: record.payload, as: UTF8.self)

        XCTAssertFalse(json.contains("checked in"), json)
        XCTAssertFalse(json.contains("ares"), json)
    }

    // MARK: Size

    /// A transcript has no cap in the local store and CloudKit has one per
    /// record. The payload cuts a runaway transcript and says so, rather
    /// than either failing the whole pass or showing a partial conversation
    /// as though it were complete.
    func testALongTranscriptIsTruncatedAndSaysSo() throws {
        let huge = String(repeating: "K0EPI-7: 0123456789\n", count: 40_000)
        let payload = payload(session("N0CVL-10", transcript: huge))

        XCTAssertTrue(payload.transcriptTruncated)
        XCTAssertLessThanOrEqual(payload.transcript.utf8.count,
                                 TerminalSessionPayload.transcriptByteLimit)
        XCTAssertTrue(payload.transcript.hasPrefix("K0EPI-7: 0123456789"))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertLessThan(try encoder.encode(payload).count,
                          CloudKitSyncTransport.inlinePayloadLimit,
                          "a capped transcript must fit inline, never on the asset path")
    }

    /// A blank relay destination is no relay destination. Left as "" the row
    /// would show "via KB5YZB-7" with no correspondent above it.
    func testABlankRelayDestinationIsNotARelay() {
        let session = TerminalSession(remote: "KB5YZB-7", relayDestination: "",
                                      startedAt: t(-60), endedAt: t(0), outcome: .closed)
        let rendered = payload(session).session
        XCTAssertNil(rendered.relayDestination)
        XCTAssertEqual(rendered.correspondent, "KB5YZB-7")
    }

    func testAShortTranscriptIsNotTruncated() {
        let payload = payload(session("N0CVL-10"))
        XCTAssertFalse(payload.transcriptTruncated)
        XCTAssertEqual(payload.transcript, "K0EPI-7: hello\nN0CVL-10: hi")
    }

    // MARK: Robustness

    /// A record that cannot be read is surfaced so the pass can isolate it,
    /// not skipped as though it had never arrived.
    func testAnUnreadablePayloadIsSurfaced() {
        let store = SpyStore()
        let source = source(store, device: "mac")
        let junk = WinlinkSyncRecord(kind: .terminalSession, id: "ipad|x",
                                     modifiedAt: t(0), payload: Data("not json".utf8))

        XCTAssertThrowsError(try source.apply([junk])) { error in
            XCTAssertEqual(error as? WinlinkSyncError,
                           .payloadUnreadable(kind: .terminalSession, id: "ipad|x"))
        }
        XCTAssertTrue(store.remote.isEmpty)
    }

    // MARK: Through the engine

    /// The whole point, end to end: a session finished on the Mac appears
    /// on the iPad as the Mac's, and nothing either device holds locally
    /// changes. This is the test that would have caught the engine refusing
    /// to push attributed kinds at all.
    func testASessionFinishedOnOneDeviceArrivesOnTheOtherAsThatDevices() async throws {
        let mac = SpyStore(), ipad = SpyStore()
        mac.local = [session("N0CVL-10")]
        ipad.local = [session("KB5YZB-7")]
        let transport = WinlinkInMemorySyncTransport()

        let macEngine = WinlinkSyncEngine(
            transport: transport,
            sources: [source(mac, device: "mac", deviceName: "Ross\u{2019}s Mac")],
            tokenStore: WinlinkMemoryTokenStore())
        let padEngine = WinlinkSyncEngine(
            transport: transport,
            sources: [source(ipad, device: "ipad", deviceName: "iPad", station: "K0EPI-1")],
            tokenStore: WinlinkMemoryTokenStore())

        let macReport = try await macEngine.sync()
        XCTAssertEqual(macReport.refused, 0, "attributed kinds are replicated, not refused")
        XCTAssertEqual(macReport.pushed, 1)

        let padReport = try await padEngine.sync()
        XCTAssertEqual(padReport.applied, 1)

        XCTAssertEqual(ipad.remote.map(\.remote), ["N0CVL-10"])
        XCTAssertEqual(ipad.remote.first?.deviceName, "Ross\u{2019}s Mac")
        XCTAssertEqual(ipad.remote.first?.provenance.station, "K0EPI-7")
        XCTAssertEqual(ipad.local.map(\.remote), ["KB5YZB-7"], "the iPad's own history is untouched")
        XCTAssertTrue(mac.remote.isEmpty, "the Mac has not pulled the iPad's session yet")

        // And back the other way on the Mac's next pass.
        _ = try await macEngine.sync()
        XCTAssertEqual(mac.remote.map(\.remote), ["KB5YZB-7"])
        XCTAssertEqual(mac.local.map(\.remote), ["N0CVL-10"])
    }
}
