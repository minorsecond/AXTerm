import XCTest
@testable import AXTerm

final class ICS309LogTests: XCTestCase {

    private func summary(_ mid: String,
                         direction: WinlinkMessageRecord.Direction,
                         at seconds: TimeInterval,
                         from: String = "w0arp",
                         to: [String] = ["k0epi"],
                         subject: String = "Sitrep") -> WinlinkMessageSummary {
        WinlinkMessageSummary(
            mid: mid,
            direction: direction,
            date: Date(timeIntervalSince1970: seconds),
            fromAddr: from,
            toAddrs: to,
            subject: subject,
            bodySize: 100,
            attachmentCount: 0,
            isRead: true,
            deliveryState: .received,
            folderId: 1,
            lastError: nil)
    }

    private func build(_ messages: [WinlinkMessageSummary],
                       start: TimeInterval = 0,
                       end: TimeInterval = 100_000) -> ICS309Log {
        ICS309Log.build(
            messages: messages,
            incidentName: "Boulder Flood",
            periodStart: Date(timeIntervalSince1970: start),
            periodEnd: Date(timeIntervalSince1970: end),
            taskName: "Winlink P2P Net",
            operatorName: "Ross Wardrup",
            stationId: "k0epi")
    }

    // MARK: - Direction

    /// The log records who sent and who received, which means direction
    /// decides which column this station's own callsign lands in.
    func testDirectionDecidesFromAndTo() {
        let log = build([
            summary("IN0000000001", direction: .inbound, at: 100, from: "w0arp"),
            summary("OUT000000001", direction: .outbound, at: 200, to: ["n0hi"]),
        ])
        XCTAssertEqual(log.entries[0].from, "W0ARP")
        XCTAssertEqual(log.entries[0].to, "K0EPI")
        XCTAssertEqual(log.entries[1].from, "K0EPI")
        XCTAssertEqual(log.entries[1].to, "N0HI")
    }

    /// One transmission to several addresses is one log row, not three.
    func testMultipleRecipientsStayOneRow() {
        let log = build([
            summary("OUT000000001", direction: .outbound, at: 100,
                    to: ["n0hi", "w0arp", "kd0ssp"]),
        ])
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].to, "N0HI, W0ARP, KD0SSP")
    }

    // MARK: - Operational period

    /// A log whose contents span a different window than its header
    /// claims is worse than no log at all.
    func testMessagesOutsideTheOperationalPeriodAreExcluded() {
        let log = build([
            summary("BEFORE000001", direction: .inbound, at: 50),
            summary("INSIDE000001", direction: .inbound, at: 150),
            summary("AFTER0000001", direction: .inbound, at: 500),
        ], start: 100, end: 200)
        XCTAssertEqual(log.entries.map(\.mid), ["INSIDE000001"])
    }

    /// The period boundaries are inclusive — traffic at the exact start
    /// or end of an operational period belongs to it.
    func testPeriodBoundariesAreInclusive() {
        let log = build([
            summary("STARTEDGE001", direction: .inbound, at: 100),
            summary("ENDEDGE00001", direction: .inbound, at: 200),
        ], start: 100, end: 200)
        XCTAssertEqual(log.entries.count, 2)
    }

    // MARK: - Ordering

    func testEntriesAreChronologicalAndDeterministic() {
        let log = build([
            summary("CCC000000001", direction: .inbound, at: 300),
            summary("AAA000000001", direction: .inbound, at: 100),
            summary("BBB000000001", direction: .inbound, at: 200),
        ])
        XCTAssertEqual(log.entries.map(\.mid),
                       ["AAA000000001", "BBB000000001", "CCC000000001"])
    }

    /// Two messages logged in the same minute must still order the same
    /// way on every run, or two exports of one incident disagree.
    func testSimultaneousMessagesBreakTiesDeterministically() {
        let a = summary("ZZZ000000001", direction: .inbound, at: 100)
        let b = summary("AAA000000001", direction: .inbound, at: 100)
        XCTAssertEqual(build([a, b]).entries.map(\.mid), build([b, a]).entries.map(\.mid))
        XCTAssertEqual(build([a, b]).entries.first?.mid, "AAA000000001")
    }

    // MARK: - Rendering

    /// Times are UTC because that is what the traffic carries and what a
    /// served agency can reconcile across stations.
    func testTimestampsAreUTC() {
        XCTAssertEqual(ICS309Log.timestamp(Date(timeIntervalSince1970: 0)),
                       "1970-01-01 00:00Z")
    }

    func testPlainTextCarriesTheFormHeaderAndEveryEntry() {
        let log = build([
            summary("IN0000000001", direction: .inbound, at: 100, subject: "Shelter status"),
            summary("OUT000000001", direction: .outbound, at: 200, subject: "ACK"),
        ])
        let text = log.renderPlainText()
        XCTAssertTrue(text.contains("ICS-309"), text)
        XCTAssertTrue(text.contains("Boulder Flood"), text)
        XCTAssertTrue(text.contains("Winlink P2P Net"), text)
        XCTAssertTrue(text.contains("Ross Wardrup"), text)
        XCTAssertTrue(text.contains("K0EPI"), text)
        XCTAssertTrue(text.contains("Shelter status"), text)
        XCTAssertTrue(text.contains("ACK"), text)
        XCTAssertTrue(text.contains("2 messages logged"), text)
    }

    /// An empty period is a real answer — say so rather than emitting a
    /// headerless blank.
    func testEmptyLogSaysSoExplicitly() {
        let text = build([]).renderPlainText()
        XCTAssertTrue(text.contains("No traffic logged"), text)
        XCTAssertTrue(text.contains("Boulder Flood"), text)
    }

    /// Subjects routinely contain commas; an unescaped one silently
    /// shifts every later column.
    func testCSVEscapesCommasAndQuotes() {
        let log = build([
            summary("IN0000000001", direction: .inbound, at: 100,
                    subject: "Shelter, 42 people"),
            summary("IN0000000002", direction: .inbound, at: 200,
                    subject: "Reported \"all clear\""),
        ])
        let csv = log.renderCSV()
        XCTAssertTrue(csv.contains("\"Shelter, 42 people\""), csv)
        XCTAssertTrue(csv.contains("\"Reported \"\"all clear\"\"\""), csv)
    }

    func testCSVHasAHeaderRowAndOneLinePerEntry() {
        let log = build([
            summary("IN0000000001", direction: .inbound, at: 100),
            summary("IN0000000002", direction: .inbound, at: 200),
        ])
        let lines = log.renderCSV().components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3, "header plus two entries")
        XCTAssertTrue(lines[0].hasPrefix("Date/Time (UTC),From,To,Subject"))
    }

    func testPageCountFollowsTheFormsRowLimit() {
        let many = (0..<(ICS309Log.rowsPerPage + 1)).map {
            summary(String(format: "MID%09d", $0), direction: .inbound, at: Double($0))
        }
        XCTAssertEqual(build(many).pageCount, 2)
        XCTAssertEqual(build([]).pageCount, 1)
    }
}
