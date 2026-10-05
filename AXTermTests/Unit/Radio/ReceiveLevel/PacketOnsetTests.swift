//
//  PacketOnsetTests.swift
//  AXTermTests
//
//  The first report of a packet is its onset and does not decide whether the
//  tones clipped.
//
//  Smoke run 2026-10-03-1, issue 44: B (ID-50) calibrated twice from A
//  (705)'s digipeat and flipped between +24 dB and +18 dB. The reports below
//  are the TNC4's own, copied from B's Link Debug log. At +24 dB the tones
//  sat at 54%, centered, with room on both sides; the first 100 ms of A's
//  tones swung about twice as wide and touched the top rail. Clipping cut
//  that report's peak-to-peak to within 30% of the tones, so it joined the
//  run and marked the whole packet clipped. At +18 dB the same onset read
//  54%, too far from the 27% tones to join, and nothing clipped.
//

import XCTest
@testable import AXTerm

final class PacketOnsetTests: XCTestCase {

    /// One TNC4 input-level report from its hex as Link Debug shows it after
    /// `06 04`: Vpp, Vavg, Vmin, Vmax, two bytes each.
    private func report(_ t: Double, _ hex: String) -> TNC4LevelSample {
        let bytes = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        precondition(bytes.count == 8, "eight bytes after 06 04")
        func word(_ i: Int) -> Int { Int(bytes[i]) << 8 | Int(bytes[i + 1]) }
        return TNC4LevelSample(t: t, vpp: word(0), vmin: word(4), vmax: word(6))
    }

    /// Calibration 1, input gain 4 (+24 dB), 2026-10-04 19:08:29 to 19:08:31
    /// MDT, times from B's beacon going out at 19:08:26.
    private var digipeatAtGain4: [TNC4LevelSample] {
        [
            report(3.1, "00 70 88 F0 88 BC 89 2C"),   // closed squelch
            report(3.2, "00 60 88 F0 88 C8 89 28"),
            report(3.3, "00 74 88 F4 88 BC 89 30"),
            report(3.4, "00 5C 88 F0 88 C0 89 1C"),
            report(3.5, "0F 5C 8D F0 86 B4 96 10"),   // A's carrier
            report(3.6, "07 28 93 C0 8F E4 97 0C"),
            report(3.7, "09 08 90 BC 8B E8 94 F0"),
            report(3.8, "B9 60 BC E4 46 40 FF A0"),   // onset: center shifted, top rail
            report(3.9, "88 B0 8A 20 44 80 D0 80"),   // tones, centered
            report(4.0, "8D 44 88 40 41 B4 CE F8"),
            report(4.1, "89 CC 87 44 42 9C CC 68"),
            report(4.2, "89 D4 86 D4 41 08 CA DC"),
            report(4.3, "8A 6C 86 BC 41 C4 CC 30"),
            report(4.4, "8D 70 86 A4 3E C0 CC 30"),
            report(4.5, "8B 70 86 C4 42 0C CD 7C"),
            report(4.6, "FF BC 86 EC 00 00 FF BC"),   // carrier drops: squelch tail
            report(4.7, "03 3C 87 2C 85 94 88 D0"),
            report(4.8, "03 40 87 58 85 C8 89 08"),
            report(5.1, "00 90 87 74 87 34 87 C4"),
        ]
    }

    /// Calibration 2, input gain 3 (+18 dB), 19:18:59 to 19:19:00 MDT.
    private var digipeatAtGain3: [TNC4LevelSample] {
        [
            report(2.5, "00 38 84 54 84 38 84 70"),   // closed squelch
            report(2.6, "06 2C 85 20 82 AC 88 D8"),   // A's carrier
            report(2.7, "03 3C 89 18 87 34 8A 70"),
            report(2.8, "03 4C 88 78 86 EC 8A 38"),
            report(2.9, "88 F8 86 A0 47 1C D0 14"),   // onset: twice the tones
            report(3.0, "45 DC 85 50 62 90 A8 6C"),   // tones
            report(3.1, "45 AC 84 30 61 74 A7 20"),
            report(3.2, "45 94 83 C4 61 30 A6 C4"),
        ]
    }

    func testTheOnsetDoesNotMarkTheTonesClipped() throws {
        let segments = PacketToneSignature.segments(in: digipeatAtGain4)
        let packet = try XCTUnwrap(segments.first)
        XCTAssertEqual(segments.count, 1)
        XCTAssertFalse(packet.clipped, "only the onset touched a rail")
        XCTAssertEqual(packet.toneFraction, 0.54, accuracy: 0.02)
    }

    func testTheOnsetIsReportedForTheEvidence() throws {
        let packet = try XCTUnwrap(PacketToneSignature.segments(in: digipeatAtGain4).first)
        XCTAssertTrue(packet.onsetClipped)
        let quiet = try XCTUnwrap(PacketToneSignature.segments(in: digipeatAtGain3).first)
        XCTAssertFalse(quiet.onsetClipped)
    }

    func testOneStepDownReadsHalfTheLevel() throws {
        let packet = try XCTUnwrap(PacketToneSignature.segments(in: digipeatAtGain3).first)
        XCTAssertFalse(packet.clipped)
        XCTAssertEqual(packet.toneFraction, 0.27, accuracy: 0.02)
    }

    /// Both calibrations now agree, so a second run confirms the first
    /// instead of undoing it.
    func testBothCalibrationsSettleOnTheSameGain() {
        func gain(_ samples: [TNC4LevelSample], at measured: Int) -> Int? {
            let reading = ReceiveLevelAnalysis.read(samples)
            guard case .recommend(let rec, _, _) = ReceiveLevelAnalysis.calibrate(reading, gain: measured, range: 0...4)
            else { return nil }
            return rec.gain
        }
        XCTAssertEqual(gain(digipeatAtGain4, at: 4), 4)
        XCTAssertEqual(gain(digipeatAtGain3, at: 3), 4)
    }

    /// Tones that really are too loud clip in every report, not only the
    /// first, and are still marked.
    func testTonesClippedThroughoutAreStillMarked() throws {
        var s = LevelSeries()
        s.silence(1)
        s.packet(tone: TNC4LevelSample.fullScale, seconds: 0.7, carrierReports: 1, clipped: true)
        s.silence(1)
        let packet = try XCTUnwrap(PacketToneSignature.segments(in: s.samples).first)
        XCTAssertTrue(packet.clipped)
    }
}
