import XCTest
@testable import AXTerm

/// The Winlink inquiry server's LIST reply is the radio-path catalog
/// index. Fixture lines are verbatim from the 2026-08-24 field capture
/// (MID 6KFOMF87WJ8T, 1466 items) including its two format quirks.
final class WinlinkCatalogListReplyTests: XCTestCase {

    private let fixtureBody = """
        Automated reply from Winlink Inquiry Server.\r
        \r
        Processed: 2026/08/23 14:09\r
        Re: INQUIRY LIST\r
        \r
        Global_Modified: 2026/08/17 20:36\r
        \r
        CATEGORY     INQUIRY_ID      SUBJECT                                                       SIZE    ORIGINATED       G/L\r
        \r
        ARCTIC_ICE   FICN10CWIS      "Iceberg Canada East Coast Waters"                            1657    2025/11/25 21:18   [G]\r
        METAR        FRA_NIC_ICAO    "Airport metar weather - Icao Nice - Cote Azur - South France"68      2025/05/31 20:55   [G]\r
        METAREA_III  W_MED_FCSTDE    "Wettervorhersagen f\u{FC}r das westliche Mittelmeer incl. Biskaya"4434    2025/05/31 20:56   [G]\r
        WX_BUOY      NDBC44033       "Station 44033 Buoy Report 44\u{B0}3'18" N 68\u{B0}59'47" Penobscot Bay"13116   2025/06/01 00:00   [G]\r
        """

    private func makeReply(from: String = "SERVICE",
                           subject: String = "INQUIRY: LIST",
                           body: String? = nil) -> WinlinkB2Message {
        WinlinkB2Message(
            mid: "6KFOMF87WJ8T",
            date: WinlinkB2Message.dateFormatter.date(from: "2026/08/23 14:09")!,
            type: .privateMessage,
            from: from,
            to: ["K0EPI-7"],
            cc: [],
            subject: subject,
            mbo: "SERVICE",
            body: Data((body ?? fixtureBody).utf8),
            attachments: [])
    }

    func testParsesFieldCaptureLines() throws {
        let items = try XCTUnwrap(WinlinkCatalogListReply.parse(makeReply()))
        XCTAssertEqual(items.count, 4)

        let ice = items[0]
        XCTAssertEqual(ice.category, "ARCTIC_ICE")
        XCTAssertEqual(ice.inquiryId, "FICN10CWIS")
        XCTAssertEqual(ice.subject, "Iceberg Canada East Coast Waters")
        XCTAssertEqual(ice.sizeEstimate, 1657)
        XCTAssertTrue(ice.enabled)
        XCTAssertEqual(ice.fetchedAt, WinlinkB2Message.dateFormatter.date(from: "2026/08/23 14:09")!)
    }

    /// A subject wide enough to fill its column runs flush against the
    /// size — "…South France"68 — with no separating whitespace.
    func testSubjectFlushAgainstSizeColumn() throws {
        let items = try XCTUnwrap(WinlinkCatalogListReply.parse(makeReply()))
        let metar = try XCTUnwrap(items.first { $0.inquiryId == "FRA_NIC_ICAO" })
        XCTAssertEqual(metar.subject, "Airport metar weather - Icao Nice - Cote Azur - South France")
        XCTAssertEqual(metar.sizeEstimate, 68)
    }

    /// Buoy positions embed `"` inside the subject; the last quote
    /// before the size terminates it.
    func testSubjectWithEmbeddedQuotes() throws {
        let items = try XCTUnwrap(WinlinkCatalogListReply.parse(makeReply()))
        let buoy = try XCTUnwrap(items.first { $0.inquiryId == "NDBC44033" })
        XCTAssertEqual(buoy.subject, "Station 44033 Buoy Report 44\u{B0}3'18\" N 68\u{B0}59'47\" Penobscot Bay")
        XCTAssertEqual(buoy.sizeEstimate, 13116)
    }

    func testNonServiceSenderIsNotAListReply() {
        XCTAssertNil(WinlinkCatalogListReply.parse(makeReply(from: "W0ARP")))
    }

    func testOrdinaryServiceMailIsNotAListReply() {
        // A catalog *item* delivery also comes from SERVICE but lacks the
        // inquiry server banner — it must not wipe the cache.
        XCTAssertNil(WinlinkCatalogListReply.parse(
            makeReply(subject: "METAREA IV forecast", body: "High seas forecast text.\r\n")))
    }

    func testBannerWithoutItemsReturnsNilNotEmpty() {
        // Zero items must be nil so a truncated reply never erases a
        // good cache with an empty replacement.
        let body = "Automated reply from Winlink Inquiry Server.\r\nRe: INQUIRY LIST\r\n"
        XCTAssertNil(WinlinkCatalogListReply.parse(makeReply(body: body)))
    }

    func testDuplicateInquiryIdsAreDeduped() throws {
        // inquiryId is the cache's primary key; a duplicated row must not
        // abort the whole replaceCatalogCache transaction.
        let body = """
            Automated reply from Winlink Inquiry Server.\r
            ARCTIC_ICE   FICN10CWIS   "First"    1657    2025/11/25 21:18   [G]\r
            ARCTIC_ICE   FICN10CWIS   "Second"   9999    2025/11/25 21:18   [G]\r
            """
        let items = try XCTUnwrap(WinlinkCatalogListReply.parse(makeReply(body: body)))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].subject, "First")
    }

    func testLatin1BodyDecodes() throws {
        // The on-air body is Latin-1 ("für", "°"), not UTF-8.
        var message = makeReply()
        message.body = Data(fixtureBody.unicodeScalars.map { UInt8($0.value & 0xFF) })
        let items = try XCTUnwrap(WinlinkCatalogListReply.parse(message))
        let german = try XCTUnwrap(items.first { $0.inquiryId == "W_MED_FCSTDE" })
        XCTAssertEqual(german.subject, "Wettervorhersagen f\u{FC}r das westliche Mittelmeer incl. Biskaya")
    }
}
