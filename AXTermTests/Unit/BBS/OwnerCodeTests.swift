//
//  OwnerCodeTests.swift
//  AXTermTests
//
//  Six-digit time-based one-time codes (TOTP, RFC 6238) for the operator's
//  owner commands from a plain terminal (Docs/RemoteAccessPlan.md, "Signing
//  in"). The code proves who is typing without hiding what is said: the
//  command goes in plain text and the code beside it.
//

import XCTest
@testable import AXTerm

final class OwnerCodeTests: XCTestCase {

    /// RFC 6238 appendix B, SHA-1, secret "12345678901234567890". The RFC
    /// lists eight digits; six are the last six.
    private let rfcSecret = Data("12345678901234567890".utf8)

    func testTheRFCVectors() {
        let vectors: [(TimeInterval, String)] = [
            (59, "287082"), (1_111_111_109, "081804"), (1_111_111_111, "050471"),
            (1_234_567_890, "005924"), (2_000_000_000, "279037"),
        ]
        for (seconds, code) in vectors {
            XCTAssertEqual(OwnerCode.code(secret: rfcSecret, at: Date(timeIntervalSince1970: seconds)), code,
                           "\(seconds)")
        }
    }

    func testBase32RoundTrips() throws {
        let secret = Data((0..<20).map { UInt8($0 * 13 & 0xFF) })
        let text = OwnerCode.base32(secret)
        XCTAssertEqual(try XCTUnwrap(OwnerCode.secret(fromBase32: text)), secret)
        XCTAssertEqual(OwnerCode.base32(Data("12345678901234567890".utf8)), "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        XCTAssertNil(OwnerCode.secret(fromBase32: "not base32!"))
    }

    /// What an authenticator app scans.
    func testTheSetupLink() {
        let link = OwnerCode.setupLink(secret: rfcSecret, station: "K0EPI-4")
        XCTAssertEqual(link, "otpauth://totp/AXTerm:K0EPI-4?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
                       + "&issuer=AXTerm&digits=6&period=30")
    }

    func testANewSecretIsTwentyRandomBytes() {
        let a = OwnerCode.newSecret(), b = OwnerCode.newSecret()
        XCTAssertEqual(a.count, 20)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Checking a typed code

    private let now = Date(timeIntervalSince1970: 1_111_111_111)

    func testTheCurrentCodeIsAccepted() {
        var checker = OwnerCode.Checker(secret: rfcSecret)
        XCTAssertEqual(checker.check(OwnerCode.code(secret: rfcSecret, at: now), at: now), .accepted)
    }

    /// A code is good for two minutes after it appears, for the trip over
    /// several digipeaters, and one step early (2026-10-12; one step either
    /// way before).
    func testACodeIsGoodForTwoMinutes() {
        var checker = OwnerCode.Checker(secret: rfcSecret)
        let late = OwnerCode.code(secret: rfcSecret, at: now.addingTimeInterval(-90))
        XCTAssertEqual(checker.check(late, at: now), .accepted)
        var other = OwnerCode.Checker(secret: rfcSecret)
        XCTAssertEqual(other.check(OwnerCode.code(secret: rfcSecret, at: now.addingTimeInterval(-180)), at: now),
                       .wrong)
    }

    /// Anyone listening heard the code, so it works once.
    func testACodeWorksOnce() {
        var checker = OwnerCode.Checker(secret: rfcSecret)
        let code = OwnerCode.code(secret: rfcSecret, at: now)
        XCTAssertEqual(checker.check(code, at: now), .accepted)
        XCTAssertEqual(checker.check(code, at: now.addingTimeInterval(5)), .used)
        // An older step than one already used is refused too.
        let earlier = OwnerCode.code(secret: rfcSecret, at: now.addingTimeInterval(-30))
        XCTAssertEqual(checker.check(earlier, at: now.addingTimeInterval(5)), .used)
    }

    /// Three wrong codes and it stops listening for a quarter of an hour.
    func testWrongCodesLockItForAWhile() {
        var checker = OwnerCode.Checker(secret: rfcSecret)
        for _ in 0..<3 { XCTAssertEqual(checker.check("000000", at: now), .wrong) }
        let good = OwnerCode.code(secret: rfcSecret, at: now)
        XCTAssertEqual(checker.check(good, at: now), .lockedOut)
        let later = now.addingTimeInterval(15 * 60 + 1)
        XCTAssertEqual(checker.check(OwnerCode.code(secret: rfcSecret, at: later), at: later), .accepted)
    }

    func testOnlySixDigitsAreACode() {
        var checker = OwnerCode.Checker(secret: rfcSecret)
        XCTAssertEqual(checker.check("12345", at: now), .wrong)
        XCTAssertEqual(checker.check("abcdef", at: now), .wrong)
    }
}
