//
//  NodeProfileHourlyBucketsTests.swift
//  AXTermTests
//
//  The Activity card's frames-per-hour chart. The contract: oldest hour
//  first, the hour ending now last, anything outside the trailing day
//  dropped — an off-by-one here silently shifts the whole picture of when
//  a station is on the air.
//

import XCTest
@testable import AXTerm

final class NodeProfileHourlyBucketsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000_000)

    func testNewestFramesLandInTheLastBucket() {
        let buckets = NodeProfile.hourlyBuckets(
            timestamps: [now.addingTimeInterval(-60),
                         now.addingTimeInterval(-30 * 60)],
            now: now)
        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets[23], 2)
        XCTAssertEqual(buckets.reduce(0, +), 2)
    }

    func testOldestInWindowLandsFirstAndOutsideIsDropped() {
        let buckets = NodeProfile.hourlyBuckets(
            timestamps: [
                now.addingTimeInterval(-23.5 * 3600),  // oldest bucket
                now.addingTimeInterval(-24.5 * 3600),  // outside the day
                now.addingTimeInterval(60)             // the future is not heard
            ],
            now: now)
        XCTAssertEqual(buckets[0], 1)
        XCTAssertEqual(buckets.reduce(0, +), 1)
    }

    func testBucketBoundariesAreHourAligned() {
        // 1h59m ago and 1h01m ago share a bucket; 59m ago is the next one.
        let buckets = NodeProfile.hourlyBuckets(
            timestamps: [now.addingTimeInterval(-119 * 60),
                         now.addingTimeInterval(-61 * 60),
                         now.addingTimeInterval(-59 * 60)],
            now: now)
        XCTAssertEqual(buckets[22], 2)
        XCTAssertEqual(buckets[23], 1)
    }

    func testHourBarHelpNamesTheWindow() {
        XCTAssertEqual(NodeProfileView.hourBarHelp(index: 23, count: 3, total: 24),
                       "3 frames heard the last hour.")
        XCTAssertEqual(NodeProfileView.hourBarHelp(index: 0, count: 0, total: 24),
                       "Nothing heard 24\u{2013}23 h ago.")
    }
}
