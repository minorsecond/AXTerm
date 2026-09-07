import XCTest
@testable import AXTerm

/// APRS position-report bytes, pinned. A beacon goes out over the air and
/// stays there, so the exact info field is golden-tested.
final class APRSBeaconTests: XCTestCase {

    private func report(_ lat: Double, _ lon: Double,
                        table: Character = "/", code: Character = "-") -> APRSBeacon.PositionReport {
        APRSBeacon.PositionReport(latitude: lat, longitude: lon, symbolTable: table, symbolCode: code)
    }

    // MARK: - Uncompressed position

    func testUncompressedPositionBytes() {
        let info = APRSBeacon.uncompressedInfo(report(39.5, -105.25, table: "/", code: ">"))
        XCTAssertEqual(info, "!3930.00N/10515.00W>")
    }

    func testSouthernAndEasternHemispheres() {
        let info = APRSBeacon.uncompressedInfo(report(-33.865, 151.209, table: "/", code: "-"))
        // 33°51.90'S, 151°12.54'E
        XCTAssertEqual(info, "!3351.90S/15112.54E-")
    }

    func testPositionAmbiguityBlanksLowMinuteDigits() {
        var r = report(39.5, -105.25, table: "/", code: "-")
        r.ambiguity = 2
        let info = APRSBeacon.uncompressedInfo(r)
        XCTAssertEqual(info, "!3930.  N/10515.  W-")
    }

    func testCourseSpeedExtension() {
        var r = report(39.5, -105.25, table: "/", code: ">")
        r.courseSpeed = APRSBeacon.CourseSpeed(courseDegrees: 90, speedKnots: 20)
        XCTAssertEqual(APRSBeacon.uncompressedInfo(r), "!3930.00N/10515.00W>090/020")
    }

    func testAltitudeAndComment() {
        var r = report(39.5, -105.25, table: "/", code: "-")
        r.altitudeFeet = 5280
        r.comment = "Colorado"
        XCTAssertEqual(APRSBeacon.uncompressedInfo(r), "!3930.00N/10515.00W-/A=005280Colorado")
    }

    func testAnOverlayTableCharacterIsHonoured() {
        // An overlay: a digit/letter table char with an alternate-table code.
        let info = APRSBeacon.uncompressedInfo(report(39.5, -105.25, table: "D", code: "#"))
        XCTAssertEqual(info, "!3930.00ND10515.00W#")
    }

    func testMinuteRoundingCarriesIntoDegrees() {
        // 39°59.999' rounds to 40°00.00'.
        let lat = 39.0 + 59.999 / 60.0
        XCTAssertEqual(APRSBeacon.latitudeField(lat, ambiguity: 0), "4000.00N")
    }

    // MARK: - Compressed position

    func testBase91Encoding() {
        XCTAssertEqual(APRSBeacon.base91(0, width: 4), "!!!!")
        XCTAssertEqual(APRSBeacon.base91(1, width: 4), "!!!\"")
        XCTAssertEqual(APRSBeacon.base91(90, width: 1), "{")
        XCTAssertEqual(APRSBeacon.base91(91, width: 2), "\"!")
    }

    func testCompressedPositionShape() {
        var r = report(39.5, -105.25, table: "/", code: "-")
        r.compressed = true
        let info = APRSBeacon.compressedInfo(r)
        // ! + table + 4 lat + 4 lon + code + 2 cs + 1 type = 14 chars.
        XCTAssertEqual(info.count, 14)
        XCTAssertTrue(info.hasPrefix("!/"))
    }
}

/// The full approved symbol set must be present so the picker offers every
/// symbol, not a subset.
final class APRSSymbolCatalogTests: XCTestCase {

    func testBothTablesAreComplete() {
        XCTAssertEqual(APRSSymbolCatalog.primary.count, 94)   // ! … ~
        XCTAssertEqual(APRSSymbolCatalog.alternate.count, 94)
        XCTAssertEqual(APRSSymbolCatalog.primary.first?.code, "!")
        XCTAssertEqual(APRSSymbolCatalog.primary.last?.code, "~")
        XCTAssertEqual(APRSSymbolCatalog.alternate.first?.code, "!")
        XCTAssertEqual(APRSSymbolCatalog.alternate.last?.code, "~")
    }

    func testEveryCodeIsUniquePerTableAndPrintable() {
        for table in [APRSSymbolCatalog.primary, APRSSymbolCatalog.alternate] {
            XCTAssertEqual(Set(table.map(\.code)).count, table.count)
            for s in table {
                let v = s.code.asciiValue ?? 0
                XCTAssertTrue((0x21...0x7E).contains(v), "code \(s.code) out of range")
            }
        }
    }

    func testLookupResolvesKnownSymbols() {
        XCTAssertEqual(APRSSymbolCatalog.symbol(table: "/", code: "-")?.label, "House QTH (VHF)")
        XCTAssertEqual(APRSSymbolCatalog.symbol(table: "/", code: ">")?.label, "Car")
        XCTAssertEqual(APRSSymbolCatalog.symbol(table: "\\", code: "_")?.label, "WX site (green digi)")
        XCTAssertTrue(APRSSymbolCatalog.symbol(table: "\\", code: "#")?.overlayable ?? false)
    }
}
