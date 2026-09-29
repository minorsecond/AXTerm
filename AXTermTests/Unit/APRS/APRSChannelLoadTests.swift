import XCTest
@testable import AXTerm

/// Measuring how busy the channel is.
final class APRSChannelLoadTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 100_000)

    func testAirtimeGrowsWithThePayloadAndThePath() {
        let short = packet(info: 10, via: [])
        let long = packet(info: 100, via: ["WIDE1", "WIDE2"])

        XCTAssertGreaterThan(APRSChannelLoadMeter.airtime(long, baud: 1200),
                             APRSChannelLoadMeter.airtime(short, baud: 1200))
    }

    /// A 1200 baud frame of about 50 octets is roughly a third of a second.
    /// Pinned loosely: the point is the order of magnitude, since the exact
    /// figure depends on bit stuffing that varies with the payload.
    func testAirtimeIsInTheRightRegion() {
        let seconds = APRSChannelLoadMeter.airtime(packet(info: 30, via: ["WIDE1"]), baud: 1200)
        XCTAssertGreaterThan(seconds, 0.2)
        XCTAssertLessThan(seconds, 0.7)
    }

    func testAnEmptyWindowIsNotBusy() {
        let load = APRSChannelLoadMeter.measure(packets: [], window: 900, now: now)

        XCTAssertEqual(load.frames, 0)
        XCTAssertEqual(load.occupancy, 0)
        XCTAssertFalse(load.isBusy)
    }

    func testFramesOutsideTheWindowAreNotCounted() {
        let old = packet(info: 30, via: [], at: now.addingTimeInterval(-1800))
        let load = APRSChannelLoadMeter.measure(packets: [old], window: 900, now: now)

        XCTAssertEqual(load.frames, 0)
    }

    /// Our own transmissions occupy the channel, but a station cannot hear
    /// itself, so counting them would mix a complete record with a partial one.
    func testOurOwnTransmissionsAreNotCounted() {
        let sent = packet(info: 30, via: [], direction: .tx)
        let load = APRSChannelLoadMeter.measure(packets: [sent], window: 900, now: now)

        XCTAssertEqual(load.frames, 0)
    }

    func testTheSameFrameByADifferentPathIsADuplicate() {
        let first = packet(info: 30, via: ["AD1CT"])
        let second = packet(info: 30, via: ["WQ8M-9"], at: now.addingTimeInterval(-5))
        let load = APRSChannelLoadMeter.measure(packets: [first, second], window: 900, now: now)

        XCTAssertEqual(load.frames, 2)
        XCTAssertEqual(load.duplicateShare, 0.5, accuracy: 0.001)
    }

    /// A station beaconing the same content twice by the same path is
    /// repeating itself, which is its business and not the network echoing.
    func testTheSameFrameByTheSamePathIsNotADuplicate() {
        let first = packet(info: 30, via: ["AD1CT"])
        let second = packet(info: 30, via: ["AD1CT"], at: now.addingTimeInterval(-5))
        let load = APRSChannelLoadMeter.measure(packets: [first, second], window: 900, now: now)

        XCTAssertEqual(load.duplicateShare, 0)
    }

    func testOccupancyRisesWithTraffic() {
        let many = (0..<100).map { packet(info: 60, via: ["WIDE1"], at: now.addingTimeInterval(-Double($0))) }
        let load = APRSChannelLoadMeter.measure(packets: many, window: 900, now: now)

        XCTAssertGreaterThan(load.occupancy, 0.05)
        XCTAssertLessThanOrEqual(load.occupancy, 1)
        XCTAssertEqual(load.framesPerMinute, 100.0 / 15, accuracy: 0.01)
    }

    private func packet(info: Int, via: [String],
                        at when: Date? = nil,
                        direction: Packet.Direction = .rx) -> Packet {
        Packet(timestamp: when ?? now,
               from: AX25Address(call: "N0CALL", ssid: 9),
               to: AX25Address(call: "APRS"),
               via: via.map { AX25Address(call: $0) },
               frameType: .ui, control: 0x03, pid: 0xF0,
               info: Data(repeating: 0x21, count: info),
               rawAx25: Data([0x00]),
               radioID: .primary, direction: direction)
    }
}

/// Assembling the two halves into what the panel shows.
final class APRSChannelReportTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 100_000)

    /// The shape of K0EPI-5's own channel: four digipeaters all hearing it
    /// direct, a two-hop path, and a channel busy enough to notice.
    func testABusyChannelWithSpareCoverageSuggestsAShorterPath() {
        let report = APRSChannelReport.build(
            packets: busyChannel(frames: 130),
            repeatHops: ["AD1CT": [0], "WQ8M-9": [0], "W0NED": [0, 1], "K5RHD-10": [0]],
            ownFramesHeardBack: 24,
            path: ["WIDE1-1", "WIDE2-1"],
            now: now)

        XCTAssertEqual(report.advice.hopsRequested, 2)
        XCTAssertEqual(report.advice.hopsNeeded, 1)
        XCTAssertTrue(report.load.isBusy)
        XCTAssertEqual(report.recommendation.verdict, .considerShortening(toHops: 1))
    }

    func testTheSameStationOnADeadChannelIsLeftAlone() {
        let report = APRSChannelReport.build(
            packets: busyChannel(frames: 4),
            repeatHops: ["AD1CT": [0], "WQ8M-9": [0], "W0NED": [0], "K5RHD-10": [0]],
            ownFramesHeardBack: 24,
            path: ["WIDE1-1", "WIDE2-1"],
            now: now)

        XCTAssertFalse(report.load.isBusy)
        XCTAssertEqual(report.recommendation.verdict, .keep)
    }

    func testAnEmptyPathReadsAsDirect() {
        let report = APRSChannelReport.build(
            packets: [], repeatHops: [:], ownFramesHeardBack: 0, path: [], now: now)

        XCTAssertEqual(report.pathDescription, "direct, no digipeaters")
        XCTAssertEqual(report.advice.hopsRequested, 0)
    }

    private func busyChannel(frames: Int) -> [Packet] {
        (0..<frames).map { index in
            Packet(timestamp: now.addingTimeInterval(-Double(index) * 6),
                   from: AX25Address(call: "N0CALL", ssid: index % 20),
                   to: AX25Address(call: "APRS"),
                   via: [AX25Address(call: "WIDE1", repeated: true)],
                   frameType: .ui, control: 0x03, pid: 0xF0,
                   info: Data(repeating: 0x21, count: 60),
                   rawAx25: Data([0x00]),
                   radioID: .primary, direction: .rx)
        }
    }
}
