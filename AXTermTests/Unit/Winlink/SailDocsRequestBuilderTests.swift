import XCTest
@testable import AXTerm

final class SailDocsRequestBuilderTests: XCTestCase {

    func testCommandLines() {
        XCTAssertEqual(
            SailDocsRequestBuilder.Request.webPage(url: " https://example.com/wx ").commandLine,
            "send https://example.com/wx")
        XCTAssertEqual(
            SailDocsRequestBuilder.Request.spotForecast(latitude: 39.7392, longitude: -104.9903).commandLine,
            "send spot:39.74N,104.99W")
        XCTAssertEqual(
            SailDocsRequestBuilder.Request.spotForecast(latitude: -33.9, longitude: 151.2).commandLine,
            "send spot:33.90S,151.20E")
        XCTAssertEqual(
            SailDocsRequestBuilder.Request.custom("  send gfs:38N,42N,102W,108W  ").commandLine,
            "send gfs:38N,42N,102W,108W")
    }

    func testBuildMessage() throws {
        let message = try XCTUnwrap(SailDocsRequestBuilder.buildMessage(
            requests: [.webPage(url: "https://example.com"), .custom("send spot:39N,105W")],
            myCallsign: "K0EPI",
            now: WinlinkB2Message.dateFormatter.date(from: "2026/08/23 12:00")!))

        XCTAssertEqual(message.to, ["SMTP:query@saildocs.com"])
        XCTAssertEqual(message.from, "K0EPI")
        XCTAssertEqual(
            String(data: message.body, encoding: .isoLatin1),
            "send https://example.com\r\nsend spot:39N,105W\r\n")
    }

    func testBuildMessageRejectsEmpty() {
        XCTAssertNil(SailDocsRequestBuilder.buildMessage(requests: [], myCallsign: "K0EPI"))
        XCTAssertNil(SailDocsRequestBuilder.buildMessage(requests: [.custom("send x")], myCallsign: ""))
    }
}
