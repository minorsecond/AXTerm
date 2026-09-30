//
//  ReceiveLevelRecordTests.swift
//  AXTermTests
//
//  What is kept per radio, how it survives, the calibration beacon limit,
//  and the analysis that turns a recording into a result.
//

import XCTest
@testable import AXTerm

final class ReceiveLevelRecordTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Beacon limit

    func testOneCalibrationBeaconPerTenMinutes() {
        XCTAssertNil(CalibrationBeaconLimit.nextAllowed(after: nil, now: t0))
        let last = t0
        XCTAssertEqual(CalibrationBeaconLimit.nextAllowed(after: last, now: t0.addingTimeInterval(60)),
                       t0.addingTimeInterval(600))
        XCTAssertEqual(CalibrationBeaconLimit.nextAllowed(after: last, now: t0.addingTimeInterval(599)),
                       t0.addingTimeInterval(600))
        XCTAssertNil(CalibrationBeaconLimit.nextAllowed(after: last, now: t0.addingTimeInterval(600)))
    }

    // MARK: Storage

    func testRecordRoundTripsThroughTheStore() {
        let store = ReceiveLevelStore(defaults: TestDefaults.make("receive-level"))
        let radio = RadioID(rawValue: "r1")
        XCTAssertEqual(store.load(radio), ReceiveLevelRecord())
        var r = ReceiveLevelRecord()
        r.baseline = ReceiveLevelBaseline(at: t0, gain: 1, toneVpp: 21_000, noiseVpp: 30_000)
        r.add(ReceiveLevelObservation(at: t0, gain: 1, noiseVpp: 30_000, clippedShare: 0, toneVpps: [20_000]))
        r.add([PacketLevelObservation(at: t0, gain: 1, toneVpp: 20_000, clipped: false)])
        r.lastCalibrationBeaconAt = t0
        r.digipeats.noteSent(at: t0)
        r.watchEnabled = false
        store.save(r, for: radio)
        XCTAssertEqual(store.load(radio), r)
        XCTAssertEqual(store.load(RadioID(rawValue: "other")), ReceiveLevelRecord())
    }

    func testDecodingToleratesMissingAndWrongFields() throws {
        let json = #"{"baseline": {"gain": 2, "toneVpp": "loud"}, "observations": [{"at": 1}], "watchEnabled": "yes", "future": 1}"#
        let r = try JSONDecoder().decode(ReceiveLevelRecord.self, from: Data(json.utf8))
        XCTAssertEqual(r.baseline?.gain, 2)
        XCTAssertNil(r.baseline?.toneVpp)
        XCTAssertEqual(r.observations.count, 1)
        XCTAssertTrue(r.watchEnabled)
        XCTAssertNil(r.lastCalibrationBeaconAt)
    }

    func testAGarbledRecordLoadsEmpty() {
        let defaults = TestDefaults.make("receive-level-garbled")
        defaults.set(Data("not json".utf8), forKey: ReceiveLevelStore.keyPrefix + "r1")
        XCTAssertEqual(ReceiveLevelStore(defaults: defaults).load(RadioID(rawValue: "r1")), ReceiveLevelRecord())
    }

    func testListsAreBounded() {
        var r = ReceiveLevelRecord()
        for i in 0..<40 {
            r.add(ReceiveLevelObservation(at: t0.addingTimeInterval(Double(i)), gain: 0, noiseVpp: i, clippedShare: 0))
            r.add([PacketLevelObservation(at: t0, gain: 0, toneVpp: i, clipped: false)])
        }
        XCTAssertEqual(r.observations.count, ReceiveLevelRecord.maxObservations)
        XCTAssertEqual(r.observations.last?.noiseVpp, 39)
        XCTAssertEqual(r.packetLevels.count, ReceiveLevelRecord.maxPacketLevels)
    }

    // MARK: Analysis

    /// Today's case end to end: two digipeats at 16% at 0 dB, after the
    /// IC-V8's unkey jolt.
    func testCalibrationFromTodaysNumbers() throws {
        var s = LevelSeries(seed: 11)
        s.noise(0.4)
        s.pinned(1.4)
        s.noise(0.8)
        s.packet(seconds: 0.6)
        s.noise(1.2)
        s.packet(tone: 10_200, seconds: 0.8)
        s.noise(0.6)
        let reading = ReceiveLevelAnalysis.read(s.samples, quietFrom: ReceiveLevelAnalysis.unkeySettleSeconds)
        XCTAssertEqual(reading.segments.count, 2)
        guard case .recommend(let rec, let packets, let noise) = ReceiveLevelAnalysis.calibrate(reading, gain: 0, range: 0...4) else {
            return XCTFail("expected a recommendation")
        }
        XCTAssertEqual(packets, 2)
        XCTAssertEqual(rec.action, .set(gain: 1))
        XCTAssertEqual(rec.measuredFraction, 0.16, accuracy: 0.01)
        let n = try XCTUnwrap(noise)
        XCTAssertTrue((30_000...40_000).contains(n))

        // Carried to +6 dB: packets double, and noise near 70% doesn't fill the range.
        let b = ReceiveLevelAnalysis.baseline(rec, packets: packets, noiseVpp: noise, at: t0, source: .beacon)
        XCTAssertEqual(b.gain, 1)
        XCTAssertEqual(Double(b.toneVpp ?? 0), 2 * Double(rec.measuredVpp), accuracy: 2)
        XCTAssertEqual(b.noiseSaturated, Double(n) * 2 >= 0.9 * 65_535)
    }

    func testNothingHeardChangesNothing() {
        var s = LevelSeries()
        s.noise(5.7)
        let reading = ReceiveLevelAnalysis.read(s.samples)
        XCTAssertEqual(ReceiveLevelAnalysis.calibrate(reading, gain: 0, range: 0...4), .nothingHeard(reports: 57))
        XCTAssertEqual(ReceiveLevelAnalysis.calibrate(ReceiveLevelAnalysis.read([]), gain: 0, range: 0...4), .noReports)
    }

    func testNoiseProjectedPastFullScaleIsSaturated() {
        let rec = ReceiveGainAdvice.recommend(toneVpp: 10_500, measuredAt: 0, clipped: false)
        let b = ReceiveLevelAnalysis.baseline(rec, packets: 1, noiseVpp: 36_000, at: t0, source: .beacon)
        XCTAssertTrue(b.noiseSaturated)
        XCTAssertEqual(b.noiseVpp, 65_535)
    }

    func testFirstSampleAtTheBaselineGainFillsItsNoise() {
        let base = ReceiveLevelBaseline(at: t0, gain: 1, toneVpp: 21_000, noiseVpp: nil)
        let wrongGain = ReceiveLevelObservation(at: t0.addingTimeInterval(60), gain: 2, noiseVpp: 30_000, clippedShare: 0)
        XCTAssertNil(ReceiveLevelAnalysis.completing(base, with: wrongGain))
        let right = ReceiveLevelObservation(at: t0.addingTimeInterval(60), gain: 1, noiseVpp: 30_000, clippedShare: 0)
        XCTAssertEqual(ReceiveLevelAnalysis.completing(base, with: right)?.noiseVpp, 30_000)
        var full = base
        full.noiseVpp = 1
        XCTAssertNil(ReceiveLevelAnalysis.completing(full, with: right))
    }

    func testPassiveNeedsThreeRecentPackets() {
        let now = t0.addingTimeInterval(3_600)
        let two = [PacketLevelObservation(at: t0, gain: 0, toneVpp: 10_000, clipped: false),
                   PacketLevelObservation(at: t0, gain: 0, toneVpp: 11_000, clipped: false)]
        XCTAssertNil(ReceiveLevelAnalysis.passive(two, currentGain: 0, range: 0...4, now: now))
        let stale = two + [PacketLevelObservation(at: t0.addingTimeInterval(-2 * 86_400), gain: 0, toneVpp: 10_500, clipped: false)]
        XCTAssertNil(ReceiveLevelAnalysis.passive(stale, currentGain: 0, range: 0...4, now: now))
        // One heard at +6 dB counts at half its level.
        let three = two + [PacketLevelObservation(at: t0, gain: 1, toneVpp: 21_000, clipped: false)]
        let p = ReceiveLevelAnalysis.passive(three, currentGain: 0, range: 0...4, now: now)
        XCTAssertEqual(p?.packets, 3)
        XCTAssertEqual(p?.recommendation.measuredVpp, 10_500)
        XCTAssertEqual(p?.recommendation.action, .set(gain: 1))
    }
}
