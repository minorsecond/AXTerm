//
//  PacketToneSignatureTests.swift
//  AXTermTests
//
//  Packets are found in a level recording by their shape (a carrier, then
//  steady tones) and nothing else is taken for one.
//

import XCTest
@testable import AXTerm

final class PacketToneSignatureTests: XCTestCase {

    func testFindsOnePacketInOpenSquelchNoise() {
        var s = LevelSeries()
        s.noise(2)
        s.packet(seconds: 0.7)
        s.noise(2)
        let segments = PacketToneSignature.segments(in: s.samples)
        XCTAssertEqual(segments.count, 1)
        let seg = try? XCTUnwrap(segments.first)
        XCTAssertEqual(Double(seg?.toneVpp ?? 0), Double(LevelSeries.tone), accuracy: 400)
        XCTAssertEqual(seg?.reports, 7)
        XCTAssertLessThan(seg?.carrierVpp ?? .max, 700)
        XCTAssertFalse(seg?.clipped ?? true)
        XCTAssertEqual(seg?.toneFraction ?? 0, 0.16, accuracy: 0.01)
    }

    func testFindsTwoDigipeats() {
        var s = LevelSeries(seed: 7)
        s.noise(1)
        s.packet(seconds: 0.6)
        s.noise(1.5)
        s.packet(tone: 11_000, seconds: 0.9)
        s.noise(1)
        let segments = PacketToneSignature.segments(in: s.samples)
        XCTAssertEqual(segments.count, 2)
        XCTAssertLessThan(segments[0].start, segments[1].start)
    }

    func testNoiseAloneHasNoPackets() {
        for seed in UInt64(1)...20 {
            var s = LevelSeries(seed: seed)
            s.noise(6)
            XCTAssertTrue(PacketToneSignature.segments(in: s.samples).isEmpty, "seed \(seed)")
        }
    }

    /// A carrier with no data (a kerchunk) drops the noise and lets it back:
    /// the noise that returns is not tones.
    func testNoiseReturningAfterACarrierIsNotAPacket() {
        for seed in UInt64(1)...20 {
            var s = LevelSeries(seed: seed)
            s.noise(1.5)
            s.packet(tone: LevelSeries.carrier, seconds: 0.5, carrierReports: 1)
            s.noise(2)
            XCTAssertTrue(PacketToneSignature.segments(in: s.samples).isEmpty, "seed \(seed)")
        }
    }

    func testTonesWithoutACarrierBeforeThemAreNotAPacket() {
        var s = LevelSeries()
        s.noise(1)
        s.packet(seconds: 0.8, carrierReports: 0)
        s.noise(1)
        XCTAssertTrue(PacketToneSignature.segments(in: s.samples).isEmpty)
    }

    func testTooShortIsNotAPacket() {
        var s = LevelSeries()
        s.noise(1)
        s.packet(seconds: 0.2)
        s.noise(1)
        XCTAssertTrue(PacketToneSignature.segments(in: s.samples).isEmpty)
    }

    func testTooLongIsNotAPacket() {
        var s = LevelSeries()
        s.noise(1)
        s.packet(seconds: 5)
        s.noise(1)
        XCTAssertTrue(PacketToneSignature.segments(in: s.samples).isEmpty)
    }

    /// With the squelch closed there is no noise and no carrier dip; the
    /// silence before the tones does the same job.
    func testFindsAPacketWithTheSquelchClosed() {
        var s = LevelSeries()
        s.silence(1)
        s.packet(seconds: 0.7, carrierReports: 0)
        s.silence(1)
        let segments = PacketToneSignature.segments(in: s.samples)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(Double(segments.first?.toneVpp ?? 0), 10_500, accuracy: 400)
    }

    /// Every level doubles per gain step, and the rules are ratios.
    func testWorksAtHigherGain() {
        var s = LevelSeries(seed: 3)
        s.noise(1, scale: 1.5)
        s.packet(seconds: 0.7, scale: 4)
        s.noise(1, scale: 1.5)
        let segments = PacketToneSignature.segments(in: s.samples)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(Double(segments.first?.toneVpp ?? 0), 42_000, accuracy: 1_600)
    }

    /// Two steps up from today's gain the open-squelch noise fills the range,
    /// and the packets must still be found under it.
    func testFindsPacketsUnderClippedNoise() {
        var s = LevelSeries(seed: 5)
        s.noise(1.5, scale: 4)
        s.packet(seconds: 0.7, scale: 4)
        s.noise(2, scale: 4)
        let segments = PacketToneSignature.segments(in: s.samples)
        XCTAssertEqual(segments.count, 1)
        XCTAssertFalse(segments.first?.clipped ?? true)
    }

    func testClippedTonesAreFoundAndMarked() {
        var s = LevelSeries()
        s.silence(1)
        s.packet(tone: TNC4LevelSample.fullScale, seconds: 0.7, carrierReports: 1, clipped: true)
        s.silence(1)
        let segments = PacketToneSignature.segments(in: s.samples)
        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments.first?.clipped ?? false)
    }

    /// The unkey jolt pins the input; pinned reports are neither a carrier
    /// nor tones.
    func testAPinnedInputIsNotAPacket() {
        var s = LevelSeries()
        s.pinned(1.5)
        s.noise(3)
        XCTAssertTrue(PacketToneSignature.segments(in: s.samples).isEmpty)
    }

    func testPacketDuringTheJoltRecoveryIsStillFound() {
        var s = LevelSeries()
        s.noise(0.5)
        s.pinned(1.2)
        s.noise(0.5)
        s.packet(seconds: 0.8)
        s.noise(2)
        XCTAssertEqual(PacketToneSignature.segments(in: s.samples).count, 1)
    }

    func testNoiseFloorLeavesOutPacketsAndClipping() {
        var s = LevelSeries()
        s.pinned(1)
        s.noise(2)
        s.packet(seconds: 0.7)
        s.noise(2)
        let segments = PacketToneSignature.segments(in: s.samples)
        let floor = PacketToneSignature.noiseFloor(in: s.samples, excluding: segments)
        XCTAssertNotNil(floor)
        XCTAssertTrue((30_000...40_000).contains(floor ?? 0), "floor \(floor ?? 0)")
    }

    func testMedian() {
        XCTAssertNil(PacketToneSignature.median([]))
        XCTAssertEqual(PacketToneSignature.median([3, 1, 2]), 2)
        XCTAssertEqual(PacketToneSignature.median([4, 1, 3, 2]), 2)
    }
}
