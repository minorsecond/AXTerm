import XCTest
@testable import AXTerm

/// The URL is guessed from the callsign, so the guessing rules are the thing
/// worth pinning down — above all, which callsigns get no link at all.
final class QRZLinkTests: XCTestCase {

    func testTheURLIsTheCallsignsPage() {
        XCTAssertEqual(QRZLink.url(for: "W1AW")?.absoluteString, "https://www.qrz.com/db/W1AW")
    }

    /// QRZ knows licences. `KF0YKI-9` is one operator's ninth station, not a
    /// ninth licensee, so the SSID goes.
    func testTheSSIDIsDropped() {
        XCTAssertEqual(QRZLink.url(for: "KF0YKI-9")?.absoluteString, "https://www.qrz.com/db/KF0YKI")
    }

    func testLowercaseIsNormalised() {
        XCTAssertEqual(QRZLink.url(for: "kj5imv")?.absoluteString, "https://www.qrz.com/db/KJ5IMV")
    }

    /// A page that will not exist is worse than no link.
    func testServiceEndpointsAndNonCallsignsGetNoLink() {
        for candidate in ["WIDE1-1", "BEACON", "NODES", "APRS", "", "T088", "12345", "-9"] {
            XCTAssertNil(QRZLink.url(for: candidate), candidate)
        }
    }

    func testTheTitleNamesTheBaseCallsign() {
        XCTAssertEqual(QRZLink.title(for: "KF0YKI-9"), "Look up KF0YKI on QRZ")
    }
}
