//
//  BBSLinkRateTests.swift
//  AXTermTests
//
//  Park rehearsal 2026-10-08, finding 35. The listing quoted a 5 KB file at
//  under a minute, from the caller's last download (about 80 B/s), while the
//  link was running stop-and-wait with 64-byte frames and took five. A
//  quote is no faster than the live link can carry.
//

import XCTest
@testable import AXTerm

final class BBSLinkRateTests: XCTestCase {

    /// The link at 16:29Z: K 1, paclen 64, a frame acknowledged every 3.3 s.
    func testCapacityIsAWindowOfFramesPerRoundTrip() throws {
        let capacity = try XCTUnwrap(BBSLinkRate.capacity(window: 1, paclen: 64, srtt: 3.3))
        XCTAssertEqual(capacity, 64 / 3.3, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(BBSLinkRate.capacity(window: 2, paclen: 128, srtt: 3.0)),
                       256 / 3.0, accuracy: 0.01)
    }

    func testNoRoundTripMeasuredYetMeansNoCapacityFigure() {
        XCTAssertNil(BBSLinkRate.capacity(window: 4, paclen: 256, srtt: nil))
        XCTAssertNil(BBSLinkRate.capacity(window: 4, paclen: 256, srtt: 0))
    }

    func testTheQuoteIsTheSlowerOfTheMeasuredRateAndTheLink() {
        XCTAssertEqual(BBSLinkRate.quoted(measured: 80, fallback: 90, capacity: 19.4), 19.4)
        XCTAssertEqual(BBSLinkRate.quoted(measured: 80, fallback: 90, capacity: 85), 80)
        XCTAssertEqual(BBSLinkRate.quoted(measured: nil, fallback: 90, capacity: 30), 30)
        XCTAssertEqual(BBSLinkRate.quoted(measured: nil, fallback: 90, capacity: nil), 90)
    }
}
