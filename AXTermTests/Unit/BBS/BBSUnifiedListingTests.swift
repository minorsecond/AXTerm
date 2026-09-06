import XCTest
@testable import AXTerm

/// What the mailbox screen lists when the operator asks to see every
/// instance, and how each row says which mailbox it belongs to.
///
/// One mailbox per device, one section per mailbox, this device's first;
/// nothing from elsewhere unless asked; every remote row labelled. The
/// same shape as the terminal's History, because the reason is the same:
/// a message from the home rig's mailbox unmarked in the iPad's list would
/// read as mail the iPad's mailbox received.
final class BBSUnifiedListingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_756_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func message(_ id: Int64, to: String = "K0EPI", from: String = "N0CVL",
                         at offset: TimeInterval = 0, killedAt: Date? = nil,
                         readAt: Date? = nil) -> BBSMessage {
        BBSMessage(id: id, from: from, to: to, subject: "S\(id)", body: "B",
                   receivedAt: t(offset), readAt: readAt, killedAt: killedAt)
    }

    private func remote(_ message: BBSMessage, mailbox: String = "K0EPI-9",
                        station: String = "K0EPI-1", device: String = "ipad",
                        deviceName: String? = "iPad") -> BBSMessagePayload {
        BBSMessagePayload(message: message, mailbox: mailbox,
                          provenance: WinlinkSyncProvenance(station: station, deviceID: device,
                                                            gridSquare: "DM79", observedAt: t(0)),
                          deviceName: deviceName)
    }

    private func call(_ id: Int64, _ callsign: String, at offset: TimeInterval = 0) -> BBSCall {
        BBSCall(id: id, callsign: callsign, connectedAt: t(offset - 60), disconnectedAt: t(offset),
                actions: [], endedUnexpectedly: false)
    }

    // MARK: Toggle and separation

    func testOtherInstancesAreAbsentUnlessAskedFor() {
        let sections = BBSUnifiedListing.messageSections(
            local: [message(1)], remote: [remote(message(1))],
            showsOtherInstances: false, filter: .all, sysop: "K0EPI")
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
        XCTAssertFalse(sections[0].isRemote)
    }

    func testRemoteMailboxesAreTheirOwnSectionsAfterThisOne() {
        let sections = BBSUnifiedListing.messageSections(
            local: [message(1)],
            remote: [remote(message(1), mailbox: "K0EPI-9", device: "ipad", deviceName: "iPad"),
                     remote(message(4, at: 10), mailbox: "K0EPI-2", device: "mac", deviceName: "Ross\u{2019}s Mac"),
                     remote(message(2, at: -10), mailbox: "K0EPI-2", device: "mac", deviceName: "Ross\u{2019}s Mac")],
            showsOtherInstances: true, filter: .all, sysop: "K0EPI")

        XCTAssertEqual(sections.map(\.title), ["This mailbox", "iPad", "Ross\u{2019}s Mac"])
        XCTAssertEqual(sections.map(\.isRemote), [false, true, true])
        XCTAssertEqual(sections[2].rows.map(\.message.id), [4, 2], "newest first within a mailbox")
        XCTAssertEqual(sections[2].attribution, "K0EPI-2\u{2019}s mailbox on Ross\u{2019}s Mac \u{b7} DM79")
    }

    func testEveryRemoteRowIsAttributed() {
        let sections = BBSUnifiedListing.messageSections(
            local: [], remote: [remote(message(1), mailbox: "K0EPI-9", deviceName: "iPad")],
            showsOtherInstances: true, filter: .all, sysop: "K0EPI")
        XCTAssertEqual(sections[0].rows[0].origin.label, "From K0EPI-9\u{2019}s mailbox on iPad")
        XCTAssertNotEqual(sections[0].rows[0].origin, .thisMailbox)
    }

    func testLocalRowsCarryNoAttribution() {
        let sections = BBSUnifiedListing.messageSections(
            local: [message(1)], remote: [], showsOtherInstances: true, filter: .all, sysop: "K0EPI")
        XCTAssertNil(sections[0].rows[0].origin.label)
        XCTAssertEqual(sections[0].rows[0].origin, .thisMailbox)
    }

    /// Message 12 exists on every mailbox; row IDs must not collide.
    func testRowIDsAreDistinctAcrossMailboxesForTheSameNumber() {
        let sections = BBSUnifiedListing.messageSections(
            local: [message(12)],
            remote: [remote(message(12), device: "ipad"), remote(message(12), device: "mac", deviceName: "Mac")],
            showsOtherInstances: true, filter: .all, sysop: "K0EPI")
        let ids = sections.flatMap { $0.rows.map(\.id) }
        XCTAssertEqual(Set(ids).count, 3)
    }

    // MARK: Filters apply to both sides

    /// "Mine" means addressed to the operator, whichever mailbox received it:
    /// mail left for K0EPI on the iPad's mailbox is still the operator's.
    func testTheFilterAppliesToRemoteRowsWithTheLocalSysop() {
        let sections = BBSUnifiedListing.messageSections(
            local: [message(1, to: "K0EPI"), message(2, to: "ALL")],
            remote: [remote(message(1, to: "K0EPI")), remote(message(2, to: "ALL")),
                     remote(message(3, to: "K0EPI", killedAt: t(5)))],
            showsOtherInstances: true, filter: .mine, sysop: "K0EPI")

        XCTAssertEqual(sections.map { $0.rows.map(\.message.id) }, [[1], [1]])
    }

    func testEmptyRemoteSectionsAreDropped() {
        let sections = BBSUnifiedListing.messageSections(
            local: [message(1, to: "ALL")], remote: [remote(message(1, to: "K0EPI"))],
            showsOtherInstances: true, filter: .bulletins, sysop: "K0EPI")
        XCTAssertEqual(sections.count, 1)
        XCTAssertFalse(sections[0].isRemote)
    }

    // MARK: Callers

    func testCallersFromOtherMailboxesAreSectionedAndLabelledTheSameWay() {
        let remoteCall = BBSCallPayload(
            call: call(9, "W0ARP-10"), mailbox: "K0EPI-9",
            provenance: WinlinkSyncProvenance(station: "K0EPI-1", deviceID: "ipad",
                                              gridSquare: nil, observedAt: t(0)),
            deviceName: "iPad")
        let sections = BBSUnifiedListing.callSections(
            local: [call(1, "N0CVL-7")], remote: [remoteCall], showsOtherInstances: true)

        XCTAssertEqual(sections.map(\.title), ["This mailbox", "iPad"])
        XCTAssertEqual(sections[1].rows[0].call.callsign, "W0ARP-10")
        XCTAssertEqual(sections[1].rows[0].origin.label, "From K0EPI-9\u{2019}s mailbox on iPad")
        XCTAssertEqual(sections[1].attribution, "K0EPI-9\u{2019}s mailbox on iPad")
    }

    func testCallersFromOtherMailboxesAreAbsentUnlessAskedFor() {
        let remoteCall = BBSCallPayload(
            call: call(9, "W0ARP-10"), mailbox: "K0EPI-9",
            provenance: WinlinkSyncProvenance(station: "K0EPI-1", deviceID: "ipad",
                                              gridSquare: nil, observedAt: t(0)),
            deviceName: "iPad")
        let sections = BBSUnifiedListing.callSections(
            local: [call(1, "N0CVL-7")], remote: [remoteCall], showsOtherInstances: false)
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
    }

    // MARK: Count line

    func testTheCountLineSaysHowMuchIsFromElsewhere() {
        XCTAssertEqual(BBSUnifiedListing.countLine(local: 3, remote: 0, noun: "message"), "3 messages")
        XCTAssertEqual(BBSUnifiedListing.countLine(local: 1, remote: 0, noun: "message"), "1 message")
        XCTAssertEqual(BBSUnifiedListing.countLine(local: 3, remote: 2, noun: "message"),
                       "3 messages \u{b7} 2 from other mailboxes")
        XCTAssertEqual(BBSUnifiedListing.countLine(local: 0, remote: 1, noun: "caller"),
                       "0 callers \u{b7} 1 from another mailbox")
    }
}
