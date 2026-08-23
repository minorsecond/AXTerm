import XCTest
@testable import AXTerm

final class WinlinkSecureLoginTests: XCTestCase {

    /// Vectors from wl2k-go fbb/secure_test.go — validated against the live CMS.
    func testKnownVectors() {
        XCTAssertEqual(WinlinkSecureLogin.response(challenge: "23753528", password: "FOOBAR"), "72768415")
        XCTAssertEqual(WinlinkSecureLogin.response(challenge: "23753528", password: "FooBar"), "95074758")
    }

    func testResponseIsAlwaysEightDecimalDigits() {
        for (challenge, password) in [("00000000", ""), ("1", "x"), ("99999999", "averylongpassword!!")] {
            let response = WinlinkSecureLogin.response(challenge: challenge, password: password)
            XCTAssertEqual(response.count, 8)
            XCTAssertTrue(response.allSatisfy(\.isNumber), "non-digit in \(response)")
        }
    }

    func testPasswordCaseChangesResponse() {
        let a = WinlinkSecureLogin.response(challenge: "12345678", password: "SECRET")
        let b = WinlinkSecureLogin.response(challenge: "12345678", password: "secret")
        XCTAssertNotEqual(a, b)
    }
}
