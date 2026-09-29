import XCTest
@testable import AXTerm

final class WinlinkSIDTests: XCTestCase {

    func testParseWinlinkCMSSID() {
        let sid = WinlinkSID.parse("[WL2K-5.0-B2FWIHJM$]")
        XCTAssertEqual(sid, WinlinkSID(product: "WL2K", version: "5.0", features: "B2FWIHJM$"))
        XCTAssertTrue(sid!.supportsB2F)
    }

    func testParseBPQB1FSIDLacksB2F() {
        let sid = WinlinkSID.parse("[BPQ-6.0.24-B1FWIHJM$]")
        XCTAssertNotNil(sid)
        XCTAssertFalse(sid!.supportsB2F, "B1F-only gateways must be detected so we can abort cleanly")
    }

    func testParseMultiHyphenVersion() {
        let sid = WinlinkSID.parse("[RMS Trimode-1.3.42.0-B2FIHM$]")
        XCTAssertEqual(sid?.product, "RMS Trimode")
        XCTAssertEqual(sid?.version, "1.3.42.0")
        XCTAssertTrue(sid!.supportsB2F)
    }

    func testParseRejectsNonSIDLines() {
        XCTAssertNil(WinlinkSID.parse("Welcome to the gateway"))
        XCTAssertNil(WinlinkSID.parse(";PQ: 23753528"))
        XCTAssertNil(WinlinkSID.parse("[]"))
        XCTAssertNil(WinlinkSID.parse("[nohyphen]"))
        XCTAssertNil(WinlinkSID.parse(""))
    }

    func testAXTermSIDRendersAndAdvertisesB2F() {
        let sid = WinlinkSID.axterm(version: "1.0")
        XCTAssertEqual(sid.rendered, "[AXTerm-1.0-B2FHM$]")
        XCTAssertTrue(sid.supportsB2F)
        XCTAssertEqual(WinlinkSID.parse(sid.rendered), sid)
    }
}
