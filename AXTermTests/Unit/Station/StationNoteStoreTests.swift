//
//  StationNoteStoreTests.swift
//  AXTermTests
//

import XCTest
import GRDB
@testable import AXTerm

final class StationNoteStoreTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SQLiteStationNoteStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteStationNoteStore(dbQueue: queue)
    }

    func testANoteRoundTrips() throws {
        let store = try makeStore()
        try store.saveNote(callsign: "W0ARP-10", body: "Answers on 145.050, not .030", now: t0)
        XCTAssertEqual(try store.note(for: "W0ARP-10")?.body, "Answers on 145.050, not .030")
    }

    func testCallsignMatchingIgnoresCaseAndSpace() throws {
        let store = try makeStore()
        try store.saveNote(callsign: " w0arp-10 ", body: "hi", now: t0)
        XCTAssertNotNil(try store.note(for: "W0ARP-10"))
    }

    func testSSIDsKeepSeparateNotes() throws {
        let store = try makeStore()
        try store.saveNote(callsign: "K0NTS-1", body: "the node", now: t0)
        try store.saveNote(callsign: "K0NTS-10", body: "the mailbox", now: t0)
        // A note about the mailbox is not a note about the node.
        XCTAssertEqual(try store.note(for: "K0NTS-1")?.body, "the node")
        XCTAssertEqual(try store.note(for: "K0NTS-10")?.body, "the mailbox")
    }

    func testEditingReplacesRatherThanDuplicates() throws {
        let store = try makeStore()
        try store.saveNote(callsign: "W0ARP-10", body: "first", now: t0)
        try store.saveNote(callsign: "W0ARP-10", body: "second", now: t0.addingTimeInterval(60))
        XCTAssertEqual(try store.note(for: "W0ARP-10")?.body, "second")
    }

    func testEmptyingANoteDeletesIt() throws {
        let store = try makeStore()
        try store.saveNote(callsign: "W0ARP-10", body: "something", now: t0)
        try store.saveNote(callsign: "W0ARP-10", body: "   \n  ", now: t0)
        // A blank row would leave an empty note section on the profile forever.
        XCTAssertNil(try store.note(for: "W0ARP-10"))
    }

    func testWhitespaceIsTrimmedOnSave() throws {
        let store = try makeStore()
        try store.saveNote(callsign: "W0ARP-10", body: "  padded  ", now: t0)
        XCTAssertEqual(try store.note(for: "W0ARP-10")?.body, "padded")
    }

    // MARK: - Attachments

    func testAPhotoAttaches() throws {
        let store = try makeStore()
        let stored = try store.addAttachment(
            callsign: "W0ARP-10", kind: .photo, name: "Antenna",
            data: Data(repeating: 0xAB, count: 512), now: t0)
        XCTAssertEqual(stored.byteCount, 512)
        XCTAssertEqual(try store.attachments(for: "W0ARP-10").map(\.name), ["Antenna"])
    }

    func testAttachmentBytesAreNotCarriedInTheList() throws {
        let store = try makeStore()
        try store.addAttachment(callsign: "W0ARP-10", kind: .photo, name: "A",
                                data: Data(repeating: 1, count: 1024), now: t0)
        let listed = try XCTUnwrap(try store.attachments(for: "W0ARP-10").first)
        // The list draws names and sizes; reading every image to do that would
        // pull megabytes off disk to render a few rows.
        XCTAssertEqual(listed.byteCount, 1024)
        XCTAssertEqual(try store.attachmentData(id: listed.id)?.count, 1024)
    }

    func testAttachmentsAreNewestFirst() throws {
        let store = try makeStore()
        try store.addAttachment(callsign: "W0ARP-10", kind: .photo, name: "old",
                                data: Data([1]), now: t0)
        try store.addAttachment(callsign: "W0ARP-10", kind: .photo, name: "new",
                                data: Data([2]), now: t0.addingTimeInterval(60))
        XCTAssertEqual(try store.attachments(for: "W0ARP-10").map(\.name), ["new", "old"])
    }

    func testAnOversizedAttachmentIsRefusedWithItsSize() throws {
        let store = try makeStore()
        let tooBig = SQLiteStationNoteStore.maximumAttachmentBytes + 1
        XCTAssertThrowsError(
            try store.addAttachment(callsign: "W0ARP-10", kind: .photo, name: "huge",
                                    data: Data(repeating: 0, count: tooBig), now: t0)
        ) { error in
            // The size has to reach the operator, who picked something and
            // deserves to know why it did not stick.
            XCTAssertEqual(error as? SQLiteStationNoteStore.StoreError,
                           .attachmentTooLarge(tooBig))
        }
        XCTAssertTrue(try store.attachments(for: "W0ARP-10").isEmpty)
    }

    func testDeletingAnAttachmentLeavesTheNote() throws {
        let store = try makeStore()
        try store.saveNote(callsign: "W0ARP-10", body: "keep me", now: t0)
        let stored = try store.addAttachment(callsign: "W0ARP-10", kind: .photo,
                                             name: "A", data: Data([1]), now: t0)
        try store.deleteAttachment(id: stored.id)
        XCTAssertTrue(try store.attachments(for: "W0ARP-10").isEmpty)
        XCTAssertEqual(try store.note(for: "W0ARP-10")?.body, "keep me")
    }

    func testAttachmentsAreScopedToTheirStation() throws {
        let store = try makeStore()
        try store.addAttachment(callsign: "W0ARP-10", kind: .photo, name: "theirs",
                                data: Data([1]), now: t0)
        XCTAssertTrue(try store.attachments(for: "K0NTS-1").isEmpty)
    }

    // MARK: - Antenna height

    func testAntennaHeightRoundTrips() throws {
        let store = try makeStore()
        try store.saveAntennaHeight(callsign: "W0ARP-10", metres: 42, now: t0)
        XCTAssertEqual(try store.antennaHeight(for: "w0arp-10"), 42)
    }

    func testUnrecordedHeightIsNilRatherThanZero() throws {
        // Zero would be a real answer — a handheld at street level — and
        // would blockade every forecast for that station.
        let store = try makeStore()
        try store.saveNote(callsign: "W0ARP-10", body: "no height known", now: t0)
        XCTAssertNil(try store.antennaHeight(for: "W0ARP-10"))
    }

    func testClearingHeightReturnsToUnknown() throws {
        let store = try makeStore()
        try store.saveAntennaHeight(callsign: "W0ARP-10", metres: 42, now: t0)
        try store.saveAntennaHeight(callsign: "W0ARP-10", metres: nil, now: t0)
        XCTAssertNil(try store.antennaHeight(for: "W0ARP-10"))
    }

    /// The height and the note share a row, and emptying one must not take
    /// the other with it.
    func testEmptyingANoteKeepsARecordedHeight() throws {
        let store = try makeStore()
        try store.saveAntennaHeight(callsign: "W0ARP-10", metres: 42, now: t0)
        try store.saveNote(callsign: "W0ARP-10", body: "temporary", now: t0)
        try store.saveNote(callsign: "W0ARP-10", body: "", now: t0)

        XCTAssertEqual(try store.antennaHeight(for: "W0ARP-10"), 42)
        XCTAssertEqual(try store.note(for: "W0ARP-10")?.body, "")
    }

    /// With nothing else in the row, an emptied note still deletes it.
    func testEmptyingANoteWithNoHeightDeletesTheRow() throws {
        let store = try makeStore()
        try store.saveNote(callsign: "W0ARP-10", body: "temporary", now: t0)
        try store.saveNote(callsign: "W0ARP-10", body: "", now: t0)
        XCTAssertNil(try store.note(for: "W0ARP-10"))
    }

    func testRecordingAHeightDoesNotDisturbAnExistingNote() throws {
        let store = try makeStore()
        try store.saveNote(callsign: "W0ARP-10", body: "keep me", now: t0)
        try store.saveAntennaHeight(callsign: "W0ARP-10", metres: 30, now: t0)
        XCTAssertEqual(try store.note(for: "W0ARP-10")?.body, "keep me")
        XCTAssertEqual(try store.antennaHeight(for: "W0ARP-10"), 30)
    }

    func testHeightsListSkipsStationsWithoutOne() throws {
        let store = try makeStore()
        try store.saveAntennaHeight(callsign: "W0ARP-10", metres: 30, now: t0)
        try store.saveNote(callsign: "K0NTS-10", body: "no height", now: t0)
        XCTAssertEqual(try store.antennaHeights(), ["W0ARP-10": 30])
    }
}
