//
//  KISSLinkNetworkErrorTextTests.swift
//  AXTermTests
//
//  A TCP link's errors, in the words the terminal and the radio's status
//  show. The framework's own text ("Network.NWError error 61") told the
//  operator nothing they could act on.
//

import Network
import XCTest
@testable import AXTerm

final class KISSLinkNetworkErrorTextTests: XCTestCase {

    private func text(_ error: NWError, waiting: Bool = false) -> String {
        KISSLinkNetwork.plainError(error, host: "192.168.3.218", port: 8001, waiting: waiting)
    }

    func testRefusedSaysNothingIsListening() {
        let line = text(.posix(.ECONNREFUSED))
        XCTAssertTrue(line.contains("192.168.3.218:8001"), line)
        XCTAssertTrue(line.contains("Nothing is answering"), line)
        XCTAssertFalse(line.contains("NWError"), line)
        XCTAssertFalse(line.contains("Still trying"), line)
    }

    func testWaitingSaysItIsStillTrying() {
        XCTAssertTrue(text(.posix(.ECONNREFUSED), waiting: true).hasSuffix("Still trying."))
    }

    func testEachCommonCauseHasItsOwnAdvice() {
        let lines = [POSIXErrorCode.ECONNREFUSED, .ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .ECONNRESET]
            .map { text(.posix($0)) }
        XCTAssertEqual(Set(lines).count, lines.count, "each cause reads differently")
        for line in lines {
            XCTAssertTrue(line.contains("192.168.3.218:8001"), line)
            XCTAssertFalse(line.contains("NWError"), line)
            XCTAssertFalse(line.contains("couldn\u{2019}t be completed"), line)
        }
    }

    func testAnUncommonCodeStillNamesThePlaceAndTheCause() {
        let line = text(.posix(.EACCES))
        XCTAssertTrue(line.hasPrefix("Can't connect to 192.168.3.218:8001 ("), line)
        XCTAssertTrue(line.lowercased().contains("permission"), line)
    }

    func testAMissingHostNameSaysSo() {
        let line = KISSLinkNetwork.plainError(.dns(-65554), host: "ham-pi.local", port: 8001, waiting: false)
        XCTAssertTrue(line.contains("Can't find ham-pi.local"), line)
    }
}
