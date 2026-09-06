import XCTest
@testable import AXTerm

/// Seeing what the operator's other mailboxes hold.
///
/// Each device runs its own mailbox with its own message numbers, its own
/// callers, and its own append-only history. What another device's mailbox
/// holds is worth reading from here — but it is that mailbox's, filed under
/// that device's name, never merged into this device's numbering or its
/// callers log. These tests are that rule.
final class BBSMailboxSyncTests: XCTestCase {

    private final class SpyStore: BBSMailboxReplicationStore, @unchecked Sendable {
        var localMessages: [BBSMessage] = []
        var localCalls: [BBSCall] = []
        var remoteMessages: [BBSMessagePayload] = []
        var remoteCalls: [BBSCallPayload] = []

        func localMessagesForPublication() throws -> [BBSMessage] { localMessages }
        func localCallsForPublication(endedSince: Date) throws -> [BBSCall] {
            localCalls.filter { ($0.disconnectedAt ?? .distantFuture) >= endedSince && !$0.isLive }
        }
        func saveRemoteMessages(_ payloads: [BBSMessagePayload]) throws {
            remoteMessages.append(contentsOf: payloads)
        }
        func saveRemoteCalls(_ payloads: [BBSCallPayload]) throws {
            remoteCalls.append(contentsOf: payloads)
        }
        func remoteMessages(limit: Int) throws -> [BBSMessagePayload] { Array(remoteMessages.prefix(limit)) }
        func remoteCalls(limit: Int) throws -> [BBSCallPayload] { Array(remoteCalls.prefix(limit)) }
    }

    private let t0 = Date(timeIntervalSince1970: 1_756_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func message(_ id: Int64, from: String = "N0CVL", to: String = "K0EPI",
                         subject: String = "Net tonight", body: String = "2000 local on 145.050",
                         at offset: TimeInterval = 0, readAt: Date? = nil,
                         killedAt: Date? = nil) -> BBSMessage {
        BBSMessage(id: id, from: from, to: to, subject: subject, body: body,
                   receivedAt: t(offset), readAt: readAt, killedAt: killedAt)
    }

    private func call(_ id: Int64, _ callsign: String = "N0CVL-7", at offset: TimeInterval = 0,
                      ended: Bool = true, actions: [String] = ["read 3"],
                      dropped: Bool = false) -> BBSCall {
        BBSCall(id: id, callsign: callsign, connectedAt: t(offset - 120),
                disconnectedAt: ended ? t(offset) : nil,
                actions: actions, endedUnexpectedly: dropped)
    }

    private func provenance(station: String = "K0EPI-1", device: String = "ipad") -> WinlinkSyncProvenance {
        WinlinkSyncProvenance(station: station, deviceID: device, gridSquare: "DM79", observedAt: t(0))
    }

    private func messageSource(_ store: SpyStore, device: String,
                               deviceName: String? = "Ross\u{2019}s Mac",
                               now: Date? = nil) -> BBSMessageSyncSource {
        let clock = now ?? t(60)
        return BBSMessageSyncSource(
            store: store, deviceID: device, deviceName: deviceName,
            mailbox: { "K0EPI-2" }, station: { "K0EPI-7" }, gridSquare: { "DM79" },
            now: { clock })
    }

    private func callSource(_ store: SpyStore, device: String,
                            deviceName: String? = "Ross\u{2019}s Mac",
                            now: Date? = nil) -> BBSCallSyncSource {
        let clock = now ?? t(60)
        return BBSCallSyncSource(
            store: store, deviceID: device, deviceName: deviceName,
            mailbox: { "K0EPI-2" }, station: { "K0EPI-7" }, gridSquare: { "DM79" },
            now: { clock })
    }

    private func record(_ payload: BBSMessagePayload) throws -> WinlinkSyncRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return WinlinkSyncRecord(kind: .bbsMessage, id: BBSMessageSyncSource.recordID(payload),
                                 modifiedAt: payload.modifiedAt, payload: try encoder.encode(payload))
    }

    private func record(_ payload: BBSCallPayload) throws -> WinlinkSyncRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return WinlinkSyncRecord(kind: .bbsCall, id: BBSCallSyncSource.recordID(payload),
                                 modifiedAt: payload.disconnectedAt, payload: try encoder.encode(payload))
    }

    // MARK: The rule

    func testMailboxKindsAreAttributedNotSynced() {
        for kind in [WinlinkSyncPolicy.Kind.bbsMessage, .bbsCall] {
            XCTAssertTrue(WinlinkSyncPolicy.isAttributed(kind), kind.rawValue)
            XCTAssertFalse(WinlinkSyncPolicy.syncedKinds.contains(kind), kind.rawValue)
            XCTAssertTrue(WinlinkSyncPolicy.replicatedKinds.contains(kind), kind.rawValue)
            XCTAssertTrue(WinlinkSyncPolicy.reason(for: kind).lowercased().contains("mailbox"), kind.rawValue)
        }
    }

    /// The reason must say why a mailbox is not merged: message numbers are
    /// promises made to callers, and two mailboxes both promised "Message 12".
    func testTheReasonNamesTheNumberingProblem() {
        XCTAssertTrue(WinlinkSyncPolicy.reason(for: .bbsMessage).lowercased().contains("number"))
    }

    func testRemoteMessagesNeverTouchLocalState() throws {
        let store = SpyStore()
        store.localMessages = [message(1)]
        let payload = BBSMessagePayload(message: message(12, subject: "From the iPad"),
                                        mailbox: "K0EPI-9", provenance: provenance(), deviceName: "iPad")

        let applied = try messageSource(store, device: "mac").apply([try record(payload)])

        XCTAssertEqual(applied, 1)
        XCTAssertEqual(store.remoteMessages.map(\.subject), ["From the iPad"])
        XCTAssertEqual(store.localMessages.map(\.id), [1], "the local mailbox must be untouched")
    }

    func testRemoteCallsNeverTouchLocalState() throws {
        let store = SpyStore()
        store.localCalls = [call(1)]
        let payload = BBSCallPayload(call: call(40, "W0ARP-10"), mailbox: "K0EPI-9",
                                     provenance: provenance(), deviceName: "iPad")

        XCTAssertEqual(try callSource(store, device: "mac").apply([try record(payload)]), 1)
        XCTAssertEqual(store.remoteCalls.map(\.callsign), ["W0ARP-10"])
        XCTAssertEqual(store.localCalls.map(\.id), [1])
    }

    func testADeviceIgnoresItsOwnEcho() throws {
        let store = SpyStore()
        let mine = BBSMessagePayload(message: message(3), mailbox: "K0EPI-2",
                                     provenance: provenance(device: "mac"), deviceName: nil)
        XCTAssertEqual(try messageSource(store, device: "mac").apply([try record(mine)]), 0)
        XCTAssertTrue(store.remoteMessages.isEmpty)
    }

    /// Which mailbox, which station, which device, and the message's own
    /// state at the time — read, killed — all survive the wire.
    func testProvenanceAndMailboxStateSurviveTheRoundTrip() throws {
        let store = SpyStore()
        let original = message(12, from: "KB5YZB", to: "ALL", subject: "Bulletin",
                               body: "Line one\nLine two", readAt: nil, killedAt: t(30))
        let payload = BBSMessagePayload(message: original, mailbox: "K0EPI-9",
                                        provenance: provenance(station: "K0EPI-1", device: "ipad"),
                                        deviceName: "Ross\u{2019}s iPad")

        try messageSource(store, device: "mac").apply([try record(payload)])

        let back = try XCTUnwrap(store.remoteMessages.first)
        XCTAssertEqual(back.message, original)
        XCTAssertEqual(back.mailbox, "K0EPI-9")
        XCTAssertEqual(back.provenance.station, "K0EPI-1")
        XCTAssertEqual(back.provenance.deviceID, "ipad")
        XCTAssertEqual(back.deviceName, "Ross\u{2019}s iPad")
        XCTAssertTrue(back.message.isBulletin)
    }

    // MARK: What is published

    /// Every message travels — the mailbox is small and append-only — and a
    /// record's date moves when its state does, so a kill or a read on the
    /// home rig is pushed again rather than suppressed by the push ledger.
    func testAMessagesRecordDateFollowsItsState() throws {
        let store = SpyStore()
        store.localMessages = [
            message(1, at: 0),
            message(2, at: 0, readAt: t(500)),
            message(3, at: 0, killedAt: t(900)),
        ]

        let records = try messageSource(store, device: "mac").localRecords()

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.modifiedAt), [t(0), t(500), t(900)])
        XCTAssertTrue(records.allSatisfy { $0.kind == .bbsMessage })
        XCTAssertEqual(records[0].id, "mac|m1")
    }

    /// The record carries the mailbox's own callsign and this station's,
    /// which can differ (a mailbox on -2, the station on -7).
    func testPublishedMessagesAreStampedWithMailboxAndStation() throws {
        let store = SpyStore()
        store.localMessages = [message(1)]
        let record = try XCTUnwrap(try messageSource(store, device: "mac").localRecords().first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(BBSMessagePayload.self, from: record.payload)

        XCTAssertEqual(payload.mailbox, "K0EPI-2")
        XCTAssertEqual(payload.provenance.station, "K0EPI-7")
        XCTAssertEqual(payload.provenance.deviceID, "mac")
        XCTAssertEqual(payload.deviceName, "Ross\u{2019}s Mac")
    }

    /// Only finished calls in the last week: a live call is rewritten when
    /// it ends, and a year of callers is the local log's job.
    func testOnlyRecentFinishedCallsArePublished() throws {
        let store = SpyStore()
        store.localCalls = [
            call(1, at: 0),
            call(2, at: 0, ended: false),
            call(3, at: -BBSCallSyncSource.window - 60),
        ]

        let records = try callSource(store, device: "mac", now: t(0)).localRecords()

        XCTAssertEqual(records.map(\.id), ["mac|c1"])
        XCTAssertEqual(records[0].modifiedAt, t(0))
    }

    func testRecordIDsCarryTheDeviceSoTwoMailboxesNeverCollideOnANumber() {
        let one = message(12)
        let fromMac = BBSMessagePayload(message: one, mailbox: "K0EPI-2",
                                        provenance: provenance(device: "mac"), deviceName: nil)
        let fromPad = BBSMessagePayload(message: one, mailbox: "K0EPI-9",
                                        provenance: provenance(device: "ipad"), deviceName: nil)
        XCTAssertNotEqual(BBSMessageSyncSource.recordID(fromMac), BBSMessageSyncSource.recordID(fromPad))
    }

    // MARK: Robustness

    func testAnUnreadablePayloadIsSurfaced() {
        let store = SpyStore()
        let junk = WinlinkSyncRecord(kind: .bbsMessage, id: "ipad|m1", modifiedAt: t(0),
                                     payload: Data("nope".utf8))
        XCTAssertThrowsError(try messageSource(store, device: "mac").apply([junk])) { error in
            XCTAssertEqual(error as? WinlinkSyncError, .payloadUnreadable(kind: .bbsMessage, id: "ipad|m1"))
        }
    }

    // MARK: Through the engine

    /// End to end: mail left on the iPad's mailbox is readable on the Mac as
    /// the iPad's, and neither device's own mailbox changes.
    func testMailLeftOnOneMailboxIsReadableOnTheOtherAsThatMailboxes() async throws {
        let mac = SpyStore(), ipad = SpyStore()
        mac.localMessages = [message(1, subject: "On the Mac")]
        ipad.localMessages = [message(1, subject: "On the iPad")]
        ipad.localCalls = [call(7, "W0ARP-10")]
        let transport = WinlinkInMemorySyncTransport()

        let macEngine = WinlinkSyncEngine(
            transport: transport,
            sources: [messageSource(mac, device: "mac"), callSource(mac, device: "mac")],
            tokenStore: WinlinkMemoryTokenStore())
        let padEngine = WinlinkSyncEngine(
            transport: transport,
            sources: [messageSource(ipad, device: "ipad", deviceName: "iPad"),
                      callSource(ipad, device: "ipad", deviceName: "iPad")],
            tokenStore: WinlinkMemoryTokenStore())

        let padFirst = try await padEngine.sync()
        XCTAssertEqual(padFirst.refused, 0)
        XCTAssertEqual(padFirst.pushed, 2)

        let macPass = try await macEngine.sync()
        XCTAssertEqual(macPass.applied, 2)

        XCTAssertEqual(mac.remoteMessages.map(\.subject), ["On the iPad"])
        XCTAssertEqual(mac.remoteMessages.first?.deviceName, "iPad")
        XCTAssertEqual(mac.remoteCalls.map(\.callsign), ["W0ARP-10"])
        XCTAssertEqual(mac.localMessages.map(\.subject), ["On the Mac"], "the Mac's own mailbox is untouched")
        XCTAssertTrue(mac.localCalls.isEmpty)
    }
}
