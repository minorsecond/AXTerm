//
//  MobilinkdReplyPropertyTests.swift
//  AXTermTests
//
//  The TNC4's hardware replies arrive as KISS frames mixed in with received
//  packets, over Bluetooth or USB in pieces of any size. Seeded properties:
//
//  - parsing any hardware frame, and folding the result into the device
//    state, never traps;
//  - a stream of replies and packets, with junk before the first frame,
//    doubled FENDs, and cuts at random points, gives back every reply and
//    every packet, in order and unchanged.
//
//  AXTERM_FUZZ_ITERATIONS, AXTERM_FUZZ_SEED and AXTERM_FUZZ_BASE work as in
//  the other property tests.
//

import XCTest
@testable import AXTerm

@MainActor
final class MobilinkdReplyPropertyTests: XCTestCase {

    /// A hardware frame, as the KISS parser hands it over: 0x06, then the
    /// code and value. Biased toward the shapes the firmware sends (one or
    /// two value bytes, extended 0xC1 replies, short text).
    private func hardwareFrame(_ rng: inout PropertyRNG) -> Data {
        var bytes: [UInt8] = [MobilinkdTNC.CMD_HARDWARE]
        if rng.chance(0.2) { bytes.append(0xC1) }
        bytes.append(rng.byte())
        let length = rng.pick([0, 1, 1, 2, 2, 3, 4, 6, rng.int(in: 0...40)])
        for _ in 0..<length { bytes.append(rng.chance(0.5) ? rng.byte() : UInt8(rng.int(in: 0x20...0x7E))) }
        return Data(bytes)
    }

    func testAnyHardwareFrameParsesWithoutTrapping() {
        checkProperty("mobilinkd.parse.total", cases: 20_000) { rng, violations in
            let frame = hardwareFrame(&rng)
            var state = MobilinkdDeviceState()
            if let reply = MobilinkdReply.parse(frame) {
                state.apply(reply, at: Date(timeIntervalSince1970: 1_800_000_000))
                // Exact lengths: a numeric reply never comes from a long frame.
                switch reply {
                case .outputGain, .inputGain, .outputTwist, .inputTwist, .persistence, .modemType:
                    violations.check(frame.count <= 5, "numeric reply from a \(frame.count)-byte frame: \(reply)")
                default:
                    break
                }
            }
            _ = MobilinkdSettings(reportedBy: state)
        }
    }

    func testRepliesAndPacketsSurviveAnyChunkingAndLineNoise() {
        checkProperty("mobilinkd.stream.chunking", cases: 3_000) { rng, violations in
            enum Item: Equatable { case reply(Data), packet(Data) }
            var items: [Item] = []
            var stream = Data()
            // Bytes before the first FEND (a port opened mid-frame) are
            // dropped. Between frames KISS cannot tell noise from a frame,
            // so there the only extra is the doubled FEND TNCs send.
            for _ in 0..<rng.int(in: 0...8) {
                var b = rng.byte()
                if b == KISS.FEND { b = 0x00 }
                stream.append(b)
            }
            for _ in 0..<rng.int(in: 1...12) {
                if rng.chance(0.3) { stream.append(KISS.FEND) }
                if rng.chance(0.5) {
                    let frame = hardwareFrame(&rng)
                    items.append(.reply(frame))
                    stream.append(KISS.FEND)
                    stream.append(KISS.escape(frame))
                    stream.append(KISS.FEND)
                } else {
                    // Payloads full of FEND and FESC, to exercise escaping.
                    let packet = Data((0..<rng.int(in: 15...80)).map { _ in
                        rng.chance(0.1) ? rng.pick([KISS.FEND, KISS.FESC]) : rng.byte()
                    })
                    items.append(.packet(packet))
                    stream.append(KISS.encodeFrame(payload: packet))
                }
            }

            var parser = KISSFrameParser()
            var got: [Item] = []
            var offset = 0
            while offset < stream.count {
                let n = min(stream.count - offset, rng.pick([1, 1, 2, 3, 7, 20, 64, 185, 512]))
                for frame in parser.feedFrames(stream.subdata(in: offset..<offset + n)) {
                    switch frame.output {
                    case .mobilinkdTelemetry(let data): got.append(.reply(data))
                    case .ax25(let data): got.append(.packet(data))
                    case .unknown: break
                    }
                }
                offset += n
            }
            violations.check(got == items, "sent \(items.count) frames, got \(got.count) back, or changed")
            // The typed replies match parsing the frames whole.
            let whole = items.compactMap { if case .reply(let d) = $0 { MobilinkdReply.parse(d) } else { nil } }
            let pieced = got.compactMap { if case .reply(let d) = $0 { MobilinkdReply.parse(d) } else { nil } }
            violations.check(whole == pieced, "replies differ after chunking")
        }
    }
}
