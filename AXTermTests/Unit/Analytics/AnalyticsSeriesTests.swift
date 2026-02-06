//
//  AnalyticsSeriesTests.swift
//  AXTermTests
//
//  Created by AXTerm on 2026-02-18.
//

import XCTest
@testable import AXTerm

final class AnalyticsSeriesTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testComputeSeriesBucketsAlignToFiveMinuteBoundaries() {
        let date1 = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 0, second: 0)
        let date2 = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 4, second: 59)
        let date3 = makeDate(year: 2026, month: 2, day: 18, hour: 6, minute: 5, second: 0)

        let packets = [
            makePacket(timestamp: date1, infoBytes: [0x01]),
            makePacket(timestamp: date2, infoBytes: [0x02]),
            makePacket(timestamp: date3, infoBytes: [0x03])
        ]

        let series = AnalyticsEngine.computeSeries(
            packets: packets,
            bucket: .fiveMinutes,
            calendar: calendar
        )

        XCTAssertEqual(series.packetsPerBucket.count, 2)
        XCTAssertEqual(series.packetsPerBucket[0].bucket, date1)
        XCTAssertEqual(series.packetsPerBucket[0].value, 2)
        XCTAssertEqual(series.packetsPerBucket[1].bucket, date3)
        XCTAssertEqual(series.packetsPerBucket[1].value, 1)
    }

    func testComputeSeriesSortedAndUniqueBuckets() {
        let date1 = makeDate(year: 2026, month: 2, day: 18, hour: 7, minute: 5, second: 1)
        let date2 = makeDate(year: 2026, month: 2, day: 18, hour: 7, minute: 15, second: 1)

        let packets = [
            makePacket(timestamp: date2, infoBytes: [0x01]),
            makePacket(timestamp: date1, infoBytes: [0x02])
        ]

        let series = AnalyticsEngine.computeSeries(
            packets: packets,
            bucket: .fiveMinutes,
            calendar: calendar
        )

        let expected1 = TimeBucket.fiveMinutes.normalizedStart(for: date1, calendar: calendar)
        let expected2 = TimeBucket.fiveMinutes.normalizedStart(for: date2, calendar: calendar)

        XCTAssertEqual(series.packetsPerBucket.map(\.bucket), [expected1, expected2])
        XCTAssertEqual(series.bytesPerBucket.map(\.bucket), [expected1, expected2])
        XCTAssertEqual(series.uniqueStationsPerBucket.map(\.bucket), [expected1, expected2])
        XCTAssertEqual(Set(series.packetsPerBucket.map(\.bucket)).count, series.packetsPerBucket.count)
    }

    func testComputeSeriesEmptyInput() {
        let series = AnalyticsEngine.computeSeries(
            packets: [],
            bucket: .hour,
            calendar: calendar
        )

        XCTAssertTrue(series.packetsPerBucket.isEmpty)
        XCTAssertTrue(series.bytesPerBucket.isEmpty)
        XCTAssertTrue(series.uniqueStationsPerBucket.isEmpty)
    }

    func testUniqueStationsPerBucketExcludesUnknowns() {
        let bucketOne = makeDate(year: 2026, month: 2, day: 18, hour: 8, minute: 10, second: 0)
        let bucketTwo = makeDate(year: 2026, month: 2, day: 18, hour: 9, minute: 10, second: 0)
        let bucketOneStart = makeDate(year: 2026, month: 2, day: 18, hour: 8, minute: 0, second: 0)
        let bucketTwoStart = makeDate(year: 2026, month: 2, day: 18, hour: 9, minute: 0, second: 0)

        let packets = [
            makePacket(timestamp: bucketOne, from: "alpha", to: "beta"),
            makePacket(timestamp: bucketOne, from: "alpha", to: nil),
            makePacket(timestamp: bucketOne, from: nil, to: "gamma"),
            makePacket(timestamp: bucketOne, from: nil, to: nil),
            makePacket(timestamp: bucketTwo, from: "delta", to: "delta")
        ]

        let series = AnalyticsEngine.computeSeries(
            packets: packets,
            bucket: .hour,
            calendar: calendar
        )

        XCTAssertEqual(series.uniqueStationsPerBucket.count, 2)
        XCTAssertEqual(series.uniqueStationsPerBucket[0].bucket, bucketOneStart)
        XCTAssertEqual(series.uniqueStationsPerBucket[0].value, 3)
        XCTAssertEqual(series.uniqueStationsPerBucket[1].bucket, bucketTwoStart)
        XCTAssertEqual(series.uniqueStationsPerBucket[1].value, 1)
    }

    func testUniqueStationsPerBucketIncludesViaByDefault() {
        let bucketStart = makeDate(year: 2026, month: 2, day: 18, hour: 10, minute: 0, second: 0)
        let bucketTimestamp = makeDate(year: 2026, month: 2, day: 18, hour: 10, minute: 3, second: 0)

        let packets = [
            makePacket(timestamp: bucketTimestamp, from: "alpha", to: "beta", via: ["dig1", "dig2"]),
            makePacket(timestamp: bucketTimestamp, from: "alpha", to: nil, via: ["dig1"])
        ]

        let series = AnalyticsEngine.computeSeries(
            packets: packets,
            bucket: .hour,
            calendar: calendar
        )

        XCTAssertEqual(series.uniqueStationsPerBucket.count, 1)
        XCTAssertEqual(series.uniqueStationsPerBucket[0].bucket, bucketStart)
        XCTAssertEqual(series.uniqueStationsPerBucket[0].value, 4)
    }
}

private extension AnalyticsSeriesTests {
    func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )) ?? Date(timeIntervalSince1970: 0)
    }

    func makePacket(
        timestamp: Date,
        from: String? = nil,
        to: String? = nil,
        via: [String] = [],
        infoBytes: [UInt8] = []
    ) -> Packet {
        Packet(
            timestamp: timestamp,
            from: from.map { AX25Address(call: $0) },
            to: to.map { AX25Address(call: $0) },
            via: via.map { AX25Address(call: $0) },
            frameType: .ui,
            info: Data(infoBytes)
        )
    }
}
