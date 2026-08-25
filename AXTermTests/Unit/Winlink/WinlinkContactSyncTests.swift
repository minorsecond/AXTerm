//
//  WinlinkContactSyncTests.swift
//  AXTermTests
//
//  The address book was declared syncable by WinlinkSyncPolicy from the start
//  and carried by nothing: the controller configured message, messageState,
//  callsignBase and operatorProfile, while the settings panel told the
//  operator that contacts sync. Reported from the field 2026-08-25 — contacts
//  entered on the Mac never appeared on the iPad.
//

import XCTest
@testable import AXTerm

/// In-memory address book, so these tests never touch SQLite.
private final class FakeContactStore: ContactStore, @unchecked Sendable {
    var rows: [WinlinkContactRecord] = []
    private var nextID: Int64 = 1
    private(set) var saveCount = 0

    func contacts() throws -> [WinlinkContactRecord] { rows }

    func searchContacts(_ query: String) throws -> [WinlinkContactRecord] { rows }

    @discardableResult
    func saveContact(_ contact: WinlinkContactRecord) throws -> WinlinkContactRecord {
        saveCount += 1
        var stored = contact
        if let id = contact.id, let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index] = stored
            return stored
        }
        stored.id = nextID
        nextID += 1
        rows.append(stored)
        return stored
    }

    func deleteContact(id: Int64) throws { rows.removeAll { $0.id == id } }
    func touchContact(address: String, at date: Date) throws {}
    func contact(forAddress address: String) throws -> WinlinkContactRecord? {
        rows.first { $0.callsign.caseInsensitiveCompare(address) == .orderedSame }
    }
}

final class WinlinkContactSyncTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func contact(name: String, call: String = "", email: String = "",
                         phone: String = "", favorite: Bool = false,
                         created: Date? = nil, updated: Date? = nil,
                         id: Int64? = nil) -> WinlinkContactRecord {
        var record = WinlinkContactRecord.empty(now: created ?? t0)
        record.id = id
        record.displayName = name
        record.callsign = call
        record.smtpEmail = email
        record.phone = phone
        record.favorite = favorite
        record.createdAt = created ?? t0
        record.updatedAt = updated ?? created ?? t0
        return record
    }

    // MARK: - The policy is now implemented

    func testContactsAreAmongTheKindsThatReplicate() {
        XCTAssertTrue(WinlinkSyncPolicy.replicatedKinds.contains(.contact))
    }

    func testTheSourceClaimsTheContactKind() {
        let source = WinlinkContactSyncSource(store: FakeContactStore())
        XCTAssertEqual(source.kind, .contact)
    }

    // MARK: - Identity across devices

    func testCallsignIsThePreferredKey() {
        let id = WinlinkContactSyncSource.recordID(for: contact(name: "Ross", call: "K0EPI"))
        XCTAssertEqual(id, "call:K0EPI")
    }

    func testCallsignKeyIsCaseInsensitive() {
        // "k0nts" and "K0NTS" are one station; two records would fight.
        XCTAssertEqual(
            WinlinkContactSyncSource.recordID(for: contact(name: "a", call: "k0nts")),
            WinlinkContactSyncSource.recordID(for: contact(name: "b", call: "K0NTS")))
    }

    func testEmailIsTheKeyWhenThereIsNoCallsign() {
        XCTAssertEqual(
            WinlinkContactSyncSource.recordID(for: contact(name: "Pat", email: "Pat@Example.COM")),
            "mail:pat@example.com")
    }

    func testNameIsTheLastResortKey() {
        // A name and a phone number is still worth carrying between devices.
        XCTAssertEqual(
            WinlinkContactSyncSource.recordID(for: contact(name: "Dispatch", phone: "555")),
            "name:dispatch")
    }

    func testAnEmptyContactHasNoIdentityAndIsNotPublished() async throws {
        let store = FakeContactStore()
        store.rows = [contact(name: "", call: "", email: "")]
        let records = try await WinlinkContactSyncSource(store: store).localRecords()
        XCTAssertTrue(records.isEmpty, "A row with nothing to match on cannot be merged anywhere")
    }

    // MARK: - Publishing

    func testEveryIdentifiableContactIsPublished() async throws {
        let store = FakeContactStore()
        store.rows = [contact(name: "Ross", call: "K0EPI"),
                      contact(name: "Pat", email: "pat@example.com")]
        let records = try await WinlinkContactSyncSource(store: store).localRecords()
        XCTAssertEqual(Set(records.map(\.id)), ["call:K0EPI", "mail:pat@example.com"])
        XCTAssertTrue(records.allSatisfy { $0.kind == .contact })
    }

    func testDuplicateLocalRowsPublishOnlyOnce() async throws {
        let store = FakeContactStore()
        store.rows = [contact(name: "Old", call: "K0NTS", updated: t0),
                      contact(name: "New", call: "k0nts", updated: t0.addingTimeInterval(60))]
        let records = try await WinlinkContactSyncSource(store: store).localRecords()
        // Publishing both would make the pair overwrite each other every pass.
        XCTAssertEqual(records.count, 1)
    }

    func testTheRecordStampIsTheContactsOwnEditTime() async throws {
        let store = FakeContactStore()
        let edited = t0.addingTimeInterval(3600)
        store.rows = [contact(name: "Ross", call: "K0EPI", updated: edited)]
        let records = try await WinlinkContactSyncSource(store: store).localRecords()
        XCTAssertEqual(records.first?.modifiedAt, edited)
    }

    // MARK: - Applying

    func testAnUnknownContactArrives() async throws {
        let store = FakeContactStore()
        let source = WinlinkContactSyncSource(store: store)
        let incoming = try await WinlinkContactSyncSource(
            store: seeded([contact(name: "Ross", call: "K0EPI", phone: "555-0100")]))
            .localRecords()

        let changed = try await source.apply(incoming)

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.rows.first?.displayName, "Ross")
        XCTAssertEqual(store.rows.first?.phone, "555-0100")
        XCTAssertNotNil(store.rows.first?.id, "A synced contact still needs a local rowid")
    }

    func testANewerEditOverwritesAnOlderLocalCopy() async throws {
        let local = FakeContactStore()
        local.rows = [contact(name: "Ross", call: "K0EPI", phone: "old",
                              updated: t0, id: 7)]
        let incoming = try await WinlinkContactSyncSource(
            store: seeded([contact(name: "Ross W", call: "K0EPI", phone: "new",
                                   updated: t0.addingTimeInterval(60))]))
            .localRecords()

        let changed = try await WinlinkContactSyncSource(store: local).apply(incoming)

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(local.rows.count, 1, "Matching on the callsign must update, not duplicate")
        XCTAssertEqual(local.rows.first?.phone, "new")
        XCTAssertEqual(local.rows.first?.id, 7, "The local rowid must survive the merge")
    }

    func testAnOlderEditIsIgnored() async throws {
        let local = FakeContactStore()
        local.rows = [contact(name: "Ross", call: "K0EPI", phone: "current",
                              updated: t0.addingTimeInterval(60), id: 3)]
        let incoming = try await WinlinkContactSyncSource(
            store: seeded([contact(name: "Ross", call: "K0EPI", phone: "stale", updated: t0)]))
            .localRecords()

        let changed = try await WinlinkContactSyncSource(store: local).apply(incoming)

        XCTAssertEqual(changed, 0)
        XCTAssertEqual(local.rows.first?.phone, "current")
        XCTAssertEqual(local.saveCount, 0, "An ignored record must not cost a database write")
    }

    func testTheSameEditArrivingBackIsNotAChange() async throws {
        let local = FakeContactStore()
        local.rows = [contact(name: "Ross", call: "K0EPI", updated: t0, id: 1)]
        let incoming = try await WinlinkContactSyncSource(store: local).localRecords()

        // Its own record, echoed by the server. Counting this as a change
        // would report movement on every quiet pass.
        let changed = try await WinlinkContactSyncSource(store: local).apply(incoming)
        XCTAssertEqual(changed, 0)
    }

    func testTheEarlierCreationDateSurvivesAMerge() async throws {
        let march = t0
        let today = t0.addingTimeInterval(86_400 * 120)
        let local = FakeContactStore()
        local.rows = [contact(name: "Ross", call: "K0EPI",
                              created: today, updated: today, id: 1)]
        let incoming = try await WinlinkContactSyncSource(
            store: seeded([contact(name: "Ross", call: "K0EPI",
                                   created: march,
                                   updated: today.addingTimeInterval(60))]))
            .localRecords()

        _ = try await WinlinkContactSyncSource(store: local).apply(incoming)

        // A contact created in March and first synced to a new iPad today
        // was not created today.
        XCTAssertEqual(local.rows.first?.createdAt, march)
    }

    func testLocalRecencyIsNotOverwrittenByAnotherDevice() async throws {
        let local = FakeContactStore()
        var mine = contact(name: "Ross", call: "K0EPI", updated: t0, id: 1)
        let usedHere = t0.addingTimeInterval(500)
        mine.lastUsedAt = usedHere
        local.rows = [mine]

        let incoming = try await WinlinkContactSyncSource(
            store: seeded([contact(name: "Ross W", call: "K0EPI",
                                   updated: t0.addingTimeInterval(60))]))
            .localRecords()
        _ = try await WinlinkContactSyncSource(store: local).apply(incoming)

        // "Recently used" describes this device's habits, like the gateway
        // ladder — it is not a fact about the person.
        XCTAssertEqual(local.rows.first?.lastUsedAt, usedHere)
        XCTAssertEqual(local.rows.first?.displayName, "Ross W", "the rest still merged")
    }

    func testFavouriteFlagTravels() async throws {
        let local = FakeContactStore()
        local.rows = [contact(name: "Ross", call: "K0EPI", favorite: false, updated: t0, id: 1)]
        let incoming = try await WinlinkContactSyncSource(
            store: seeded([contact(name: "Ross", call: "K0EPI", favorite: true,
                                   updated: t0.addingTimeInterval(60))]))
            .localRecords()

        _ = try await WinlinkContactSyncSource(store: local).apply(incoming)
        XCTAssertTrue(try XCTUnwrap(local.rows.first?.favorite))
    }

    func testAnUnreadablePayloadSkipsOneContactNotThePass() async throws {
        let local = FakeContactStore()
        let good = try await WinlinkContactSyncSource(
            store: seeded([contact(name: "Ross", call: "K0EPI")])).localRecords()
        let bad = WinlinkSyncRecord(kind: .contact, id: "call:FUTURE",
                                    modifiedAt: t0, payload: Data([0xFF, 0x00]))

        // Written by a newer version. Losing one contact beats stalling the
        // whole mailbox.
        let changed = try await WinlinkContactSyncSource(store: local).apply(bad_first(bad, good))
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(local.rows.count, 1)
    }

    func testRecordsOfOtherKindsAreIgnored() async throws {
        let local = FakeContactStore()
        let foreign = WinlinkSyncRecord(kind: .message, id: "MID1",
                                        modifiedAt: t0, payload: Data())
        let changed = try await WinlinkContactSyncSource(store: local).apply([foreign])
        XCTAssertEqual(changed, 0)
        XCTAssertTrue(local.rows.isEmpty)
    }

    // MARK: - Helpers

    private func seeded(_ rows: [WinlinkContactRecord]) -> FakeContactStore {
        let store = FakeContactStore()
        store.rows = rows
        return store
    }

    private func bad_first(_ bad: WinlinkSyncRecord,
                           _ good: [WinlinkSyncRecord]) -> [WinlinkSyncRecord] {
        [bad] + good
    }
}
