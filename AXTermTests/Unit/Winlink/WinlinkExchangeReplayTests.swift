//
//  WinlinkExchangeReplayTests.swift
//  AXTermTests
//
//  The replay sequence diagram collapses runs of binary-block transcript
//  lines into one thick arrow. That hinges on recognizing the console's wire
//  summaries ("‹N bytes…›") — pin the parser to the exact strings
//  WinlinkExchangeSummary emits.
//

import XCTest
@testable import AXTerm

@MainActor
final class WinlinkExchangeReplayTests: XCTestCase {

    func testRecognizesBothConsoleBinarySummaryForms() async {
        XCTAssertEqual(WinlinkExchangeReplayView.binaryChunkBytes("‹128 bytes of compressed message data›"), 128)
        XCTAssertEqual(WinlinkExchangeReplayView.binaryChunkBytes("‹42 bytes›"), 42)
    }

    func testRejectsOrdinaryProtocolLines() async {
        XCTAssertNil(WinlinkExchangeReplayView.binaryChunkBytes("FS YY"))
        XCTAssertNil(WinlinkExchangeReplayView.binaryChunkBytes("FC EM ABC123 1234 800 0"))
        XCTAssertNil(WinlinkExchangeReplayView.binaryChunkBytes(""))
        XCTAssertNil(WinlinkExchangeReplayView.binaryChunkBytes("128 bytes without the marker"),
                     "must require the ‹ prefix, not just the word 'bytes'")
        XCTAssertNil(WinlinkExchangeReplayView.binaryChunkBytes("‹no leading digits bytes›"))
    }
}
