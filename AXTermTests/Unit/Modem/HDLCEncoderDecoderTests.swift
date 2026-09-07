import XCTest
@testable import AXTerm

/// Frames in, bits out, frames back — with every edge the HDLC rules have.
final class HDLCEncoderDecoderTests: XCTestCase {

    // MARK: - Helpers

    /// Encode frames into NRZI levels for one transmission.
    private func levels(for frames: [Data], txDelayMs: Int = 300, txTailMs: Int = 100,
                        baud: Double = 1200) -> [Bool] {
        var encoder = HDLCEncoder(baud: baud, txDelayMs: txDelayMs, txTailMs: txTailMs)
        for frame in frames { XCTAssertTrue(encoder.append(frame: frame)) }
        var out: [Bool] = []
        while let level = encoder.nextBit() { out.append(level) }
        return out
    }

    /// Decode NRZI levels, collecting every event but `.none`.
    private func decode(_ levels: [Bool], invert: Bool = false,
                        limits: HDLCDecoder.Limits = HDLCDecoder.Limits()) -> (events: [HDLCDecoder.Event], decoder: HDLCDecoder) {
        var nrzi = NRZIDecoder()
        var decoder = HDLCDecoder(limits: limits)
        var events: [HDLCDecoder.Event] = []
        for level in levels {
            let event = decoder.push(bit: nrzi.decode(level: level != invert))
            if event != .none { events.append(event) }
        }
        return (events, decoder)
    }

    private func frames(from events: [HDLCDecoder.Event]) -> [Data] {
        events.compactMap { if case .frame(let data) = $0 { return data } else { return nil } }
    }

    private func randomPayload(_ rng: inout SystemRandomNumberGenerator, length: Int? = nil) -> Data {
        let n = length ?? Int.random(in: 15...300, using: &rng)
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    /// A raw (pre-NRZI) bit stream for arbitrary bytes, stuffing included, so
    /// tests can put a wrong FCS on the air — the real encoder never would.
    private func rawBits(flags: Int, bytes: [UInt8], closingFlags: Int = 1) -> [Bool] {
        var bits: [Bool] = []
        func flag() { for i in 0..<8 { bits.append((0x7E >> i) & 1 == 1) } }
        for _ in 0..<flags { flag() }
        var ones = 0
        for byte in bytes {
            for i in 0..<8 {
                let bit = (byte >> i) & 1 == 1
                bits.append(bit)
                if bit { ones += 1; if ones == 5 { bits.append(false); ones = 0 } } else { ones = 0 }
            }
        }
        for _ in 0..<closingFlags { flag() }
        return bits
    }

    private func nrzi(_ raw: [Bool]) -> [Bool] {
        var encoder = NRZIEncoder()
        return raw.map { encoder.encode(bit: $0) }
    }

    // MARK: - Flags

    func testFlagCountsFollowTXDELAYAndTXTAIL() {
        XCTAssertEqual(HDLCEncoder.flagCount(milliseconds: 300, baud: 1200), 45)
        XCTAssertEqual(HDLCEncoder.flagCount(milliseconds: 100, baud: 1200), 15)
        XCTAssertEqual(HDLCEncoder.flagCount(milliseconds: 300, baud: 300), 12)
        XCTAssertEqual(HDLCEncoder.flagCount(milliseconds: 0, baud: 1200), 1, "never fewer than one")
    }

    func testATransmissionIsPreambleFrameTail() {
        let frame = Data("K0EPI-7 > CQ test".utf8)
        let (events, _) = decode(levels(for: [frame]))
        let frameIndex = events.firstIndex { if case .frame = $0 { return true } else { return false } }!
        // 45 preamble flags are sent; the very first level has no predecessor
        // for NRZI, so the first flag is unrecognisable and 44 are seen.
        XCTAssertEqual(frameIndex, 44, "44 recognised preamble flags, then the frame closes on the next")
        // 15 tail flags are sent; the first of them closes the frame.
        XCTAssertEqual(events.suffix(from: frameIndex + 1).count, 14, "14 tail flags after the closing one")
        XCTAssertTrue(events.suffix(from: frameIndex + 1).allSatisfy { $0 == .flag })
        XCTAssertEqual(frames(from: events), [frame])
    }

    // MARK: - Round trips

    func testRandomFramesRoundTrip() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let frame = randomPayload(&rng)
            XCTAssertEqual(frames(from: decode(levels(for: [frame])).events), [frame])
        }
    }

    func testStuffingHeavyPayloadsRoundTrip() {
        let allOnes = Data(repeating: 0xFF, count: 64)
        let flagsInside = Data([0x7E, 0x7E, 0x7D, 0x7E, 0xFF, 0x7E] + Array(repeating: 0x7E, count: 20))
        let alternating = Data((0..<64).map { $0 % 2 == 0 ? UInt8(0xFE) : UInt8(0x7F) })
        for frame in [allOnes, flagsInside, alternating] {
            XCTAssertEqual(frames(from: decode(levels(for: [frame])).events), [frame])
        }
    }

    /// Payloads whose FCS bytes contain runs of ones get stuffed too.
    func testFiveOnesStraddlingTheFCSAreStuffed() {
        // Search for a payload whose FCS low byte starts with ones so the run
        // continues from the last data byte into the FCS.
        var found = 0
        for seed in 0..<2000 where found < 5 {
            let payload = Data([0xF8 | UInt8(seed & 7), UInt8(seed >> 3), 0xAA, 0x55] + Array(repeating: 0x00, count: 12))
            let (lo, _) = CRC16X25.fcsBytes(for: payload)
            guard lo & 0x07 == 0x07 else { continue }
            found += 1
            XCTAssertEqual(frames(from: decode(levels(for: [payload])).events), [payload])
        }
        XCTAssertGreaterThan(found, 0)
    }

    func testAnInvertedLineDecodesTheSameFrames() {
        var rng = SystemRandomNumberGenerator()
        let frame = randomPayload(&rng)
        XCTAssertEqual(frames(from: decode(levels(for: [frame]), invert: true).events), [frame])
    }

    // MARK: - Several frames, one transmission

    func testBackToBackFramesShareTwoFlags() {
        let a = Data("first frame payload".utf8), b = Data("second frame, long enough".utf8), c = Data(repeating: 0x33, count: 40)
        let (events, _) = decode(levels(for: [a, b, c]))
        XCTAssertEqual(frames(from: events), [a, b, c])
        // Between two frames: exactly the inter-frame flags minus the one
        // that closes the earlier frame (reported as the frame itself).
        let indices = events.indices.filter { if case .frame = events[$0] { return true } else { return false } }
        XCTAssertEqual(indices[1] - indices[0] - 1, 1, "two flags: one closes a, one opens b")
        XCTAssertEqual(indices[2] - indices[1] - 1, 1)
    }

    func testFramesCanBeAppendedUntilTheTailStarts() {
        var encoder = HDLCEncoder(baud: 1200, txDelayMs: 10, txTailMs: 10)
        XCTAssertTrue(encoder.append(frame: Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])))
        var bits: [Bool] = []
        while !encoder.hasStartedTail, let bit = encoder.nextBit() { bits.append(bit) }
        XCTAssertTrue(encoder.hasStartedTail)
        XCTAssertFalse(encoder.append(frame: Data(repeating: 0x42, count: 20)), "too late for this transmission")
        while let bit = encoder.nextBit() { bits.append(bit) }
        XCTAssertTrue(encoder.isDone)
        XCTAssertEqual(frames(from: decode(bits).events).count, 1)
    }

    // MARK: - Bounds

    func testFrameLengthBounds() {
        let smallest = Data(repeating: 0x11, count: 15)     // 17 with FCS
        let tooSmall = Data(repeating: 0x11, count: 14)
        let largest = Data(repeating: 0x22, count: 1022)    // 1024 with FCS
        let tooLarge = Data(repeating: 0x22, count: 1023)

        XCTAssertEqual(frames(from: decode(levels(for: [smallest])).events), [smallest])
        XCTAssertEqual(frames(from: decode(levels(for: [largest])).events), [largest])

        let small = decode(levels(for: [tooSmall]))
        XCTAssertTrue(frames(from: small.events).isEmpty)
        XCTAssertEqual(small.decoder.discardedFragments, 1)

        let large = decode(levels(for: [tooLarge]))
        XCTAssertTrue(frames(from: large.events).isEmpty)
        XCTAssertTrue(large.events.contains(.tooLong))
    }

    // MARK: - Damage

    func testAWrongFCSIsReportedNotDelivered() {
        let payload = Array(repeating: UInt8(0x5A), count: 20)
        var bytes = payload
        let (lo, hi) = CRC16X25.fcsBytes(for: payload)
        bytes += [lo ^ 0x01, hi]
        let (events, _) = decode(nrzi(rawBits(flags: 3, bytes: bytes)))
        XCTAssertTrue(frames(from: events).isEmpty)
        XCTAssertTrue(events.contains(.fcsError(length: 22)))
    }

    func testAnAbortDropsTheFrameAndTheNextOneDecodes() {
        let good = Data("after the abort".utf8 + [0, 0, 0, 0])
        var raw = rawBits(flags: 2, bytes: [0x12, 0x34, 0x56, 0x78, 0x9A], closingFlags: 0)
        raw += Array(repeating: true, count: 9)          // seven or more ones: abort
        raw += rawBits(flags: 2, bytes: [UInt8](good) + { let (l, h) = CRC16X25.fcsBytes(for: [UInt8](good)); return [l, h] }())
        let (events, _) = decode(nrzi(raw))
        XCTAssertTrue(events.contains(.abort))
        XCTAssertEqual(frames(from: events), [good])
    }

    /// Random damage never produces a frame that was not sent, beyond the
    /// 1-in-65 536 the FCS allows.
    func testDamagedStreamsDoNotYieldFalseFrames() {
        var rng = SystemRandomNumberGenerator()
        var falseFrames = 0
        var trials = 0
        for _ in 0..<3000 {
            let frame = randomPayload(&rng, length: Int.random(in: 15...120, using: &rng))
            var stream = levels(for: [frame], txDelayMs: 20, txTailMs: 20)
            // Damage inside the frame: flip, insert or delete a few bits.
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let index = Int.random(in: 24..<(stream.count - 24), using: &rng)
                switch Int.random(in: 0...2, using: &rng) {
                case 0: stream[index].toggle()
                case 1: stream.insert(Bool.random(using: &rng), at: index)
                default: stream.remove(at: index)
                }
            }
            for decoded in frames(from: decode(stream).events) where decoded != frame {
                falseFrames += 1
            }
            trials += 1
        }
        XCTAssertLessThanOrEqual(falseFrames, 2, "\(falseFrames) false frames in \(trials) damaged streams")
    }

    // MARK: - Activity, for carrier detect

    func testActivityFollowsFlagsAndData() {
        var nrzi = NRZIDecoder()
        var decoder = HDLCDecoder()
        XCTAssertEqual(decoder.activity, .idle)
        let stream = levels(for: [Data(repeating: 0x77, count: 20)], txDelayMs: 20, txTailMs: 20)
        var seenFlags = false, seenInFrame = false
        for (i, level) in stream.enumerated() {
            _ = decoder.push(bit: nrzi.decode(level: level))
            if i == 20 { XCTAssertEqual(decoder.activity, .flags); seenFlags = true }
            if decoder.activity == .inFrame { seenInFrame = true }
        }
        XCTAssertTrue(seenFlags && seenInFrame)
        for _ in 0..<10 { _ = decoder.push(bit: true) }
        XCTAssertEqual(decoder.activity, .idle, "a long run of ones is an idle line")
    }

    // MARK: - Dedup across slicers

    func testTheSameFrameFromTwoSlicersIsDeliveredOnce() {
        var dedup = FrameDeduplicator(windowBitTimes: 64)
        let frame = Data("same bytes".utf8)
        XCTAssertTrue(dedup.shouldDeliver(frame, slicer: 0, atBit: 1000))
        XCTAssertFalse(dedup.shouldDeliver(frame, slicer: 1, atBit: 1003))
        XCTAssertFalse(dedup.shouldDeliver(frame, slicer: 2, atBit: 1040))
        XCTAssertEqual(dedup.suppressed, 2)
        // A genuine repeat, well outside the window, is a frame again.
        XCTAssertTrue(dedup.shouldDeliver(frame, slicer: 0, atBit: 1000 + 600))
        XCTAssertTrue(dedup.shouldDeliver(Data("other".utf8), slicer: 1, atBit: 1601))
    }
}
