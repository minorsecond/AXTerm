//
//  KISSAX25DecodePropertyTests.swift
//  AXTermTests
//
//  Seeded property tests for KISS deframing and AX.25 decoding under random
//  and hostile input (CLAUDE.md §4 and §13).
//
//  Properties:
//    K1  KISS escape/unescape round-trips any payload, and an escaped
//        payload never contains FEND.
//    K2  A stream of valid KISS frames reassembles identically however it
//        is split: at every single byte boundary, one byte at a time, and
//        in random chunks. Ports survive.
//    K3  On arbitrary byte streams the parser agrees with a reference
//        deframer, is independent of chunking, never emits an empty DATA
//        payload and never emits `.unknown`.
//    K4  Oversized and unterminated frames do not stop the next valid frame.
//    K5  A FESC followed by anything but TFEND/TFESC, or a FESC at the end
//        of a frame, is detected so the frame can be logged.
//    A1  Valid frames of every type round-trip encode -> decode -> encode
//        byte-identically, with 0 to 8 digipeaters and 0 to 2048 info
//        bytes, directly and through KISS.
//    A2  Decoding is total and deterministic on random and mutated input:
//        it never traps, the same bytes always give the same answer, a
//        refusal always carries a reason, an accepted frame's fields agree
//        with its bytes, and a Data slice decodes like a fresh copy.
//    A3  Address-field extension bits: where the first set bit falls
//        decides exactly between ends-after-destination, a decode with
//        that many digipeaters, too many digipeaters, an unterminated field
//        and a missing control field.
//    A4  Every frame PacketEngine cannot decode is logged as a parser
//        warning, once.
//    A5  All 256 control bytes, with any trailer, classify the same way in
//        AX25.checkFrame and AX25ControlFieldDecoder, and the PID/info split
//        follows the frame type.
//

import XCTest
@testable import AXTerm

// MARK: - Generators

nonisolated enum AX25Gen {
    static let callsignAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    static func callsign(_ rng: inout PropertyRNG) -> String {
        let length = rng.int(in: 1...6)
        return String((0..<length).map { _ in rng.pick(callsignAlphabet) })
    }

    static func address(_ rng: inout PropertyRNG) -> AX25Address {
        AX25Address(call: callsign(&rng), ssid: rng.int(in: 0...15))
    }

    /// Info lengths weighted toward the edges: empty, one byte, exactly
    /// 256 (the usual N1), and a few far past it.
    static func infoLength(_ rng: inout PropertyRNG) -> Int {
        switch rng.int(10) {
        case 0: return 0
        case 1: return 1
        case 2: return 256
        case 3: return rng.int(in: 257...2048)
        default: return rng.int(in: 0...255)
        }
    }

    /// Bytes biased toward the KISS specials so escaping is exercised.
    static func kissHeavyBytes(_ rng: inout PropertyRNG, count: Int) -> Data {
        let specials: [UInt8] = [KISS.FEND, KISS.FESC, KISS.TFEND, KISS.TFESC]
        var data = Data(capacity: count)
        for _ in 0..<count {
            data.append(rng.chance(0.25) ? rng.pick(specials) : rng.byte())
        }
        return data
    }

    enum Kind: CaseIterable { case i, ui, rr, rnr, rej, srej, sabm, sabme, disc, ua, dm, frmr }

    struct Expected {
        let to: AX25Address
        let from: AX25Address
        let via: [AX25Address]
        let control: UInt8
        let pid: UInt8?
        let info: Data
        let frameType: FrameType
    }

    /// A valid frame built with the AX25 encoders, and what it must decode to.
    static func validFrame(_ rng: inout PropertyRNG, maxInfo: Int? = nil) -> (bytes: Data, expected: Expected) {
        let to = address(&rng)
        let from = address(&rng)
        let via = (0..<rng.int(in: 0...8)).map { _ in address(&rng) }
        let kind = rng.pick(Kind.allCases)
        let pf = rng.chance(0.5)
        var length = infoLength(&rng)
        if let maxInfo { length = min(length, maxInfo) }
        let info = kissHeavyBytes(&rng, count: length)
        let pid = rng.chance(0.7) ? UInt8(0xF0) : rng.byte()

        let bytes: Data
        let control: UInt8
        switch kind {
        case .i:
            let ns = rng.int(8), nr = rng.int(8)
            bytes = AX25.encodeIFrame(from: from, to: to, via: via, ns: ns, nr: nr, pf: pf, pid: pid, info: info)
            control = AX25.encodeControlField(frameType: .i, ns: ns, nr: nr, pf: pf)[0]
            return (bytes, Expected(to: to, from: from, via: via, control: control, pid: pid, info: info, frameType: .i))
        case .ui:
            bytes = AX25.encodeUIFrame(from: from, to: to, via: via, pid: pid, info: info)
            return (bytes, Expected(to: to, from: from, via: via, control: 0x03, pid: pid, info: info, frameType: .ui))
        case .rr, .rnr, .rej, .srej:
            let type: AX25.TxFrameType = kind == .rr ? .rr : kind == .rnr ? .rnr : kind == .rej ? .rej : .srej
            let nr = rng.int(8)
            bytes = AX25.encodeSFrame(from: from, to: to, via: via, type: type, nr: nr, pf: pf)
            control = AX25.encodeControlField(frameType: type, nr: nr, pf: pf)[0]
            return (bytes, Expected(to: to, from: from, via: via, control: control, pid: nil, info: Data(), frameType: .s))
        case .sabm, .sabme, .disc, .ua, .dm, .frmr:
            let type: AX25.TxFrameType
            switch kind {
            case .sabm: type = .sabm
            case .sabme: type = .sabme
            case .disc: type = .disc
            case .ua: type = .ua
            case .dm: type = .dm
            default: type = .frmr
            }
            bytes = AX25.encodeUFrame(from: from, to: to, via: via, type: type, pf: pf)
            control = AX25.encodeControlField(frameType: type, pf: pf)[0]
            return (bytes, Expected(to: to, from: from, via: via, control: control, pid: nil, info: Data(), frameType: .u))
        }
    }

    /// Re-encodes a decoded frame with the same encoders.
    static func reencode(_ frame: AX25.FrameDecodeResult) -> Data? {
        guard let to = frame.to, let from = frame.from else { return nil }
        var data = Data()
        data.append(AX25.encodeAddress(to, isLast: false))
        data.append(AX25.encodeAddress(from, isLast: frame.via.isEmpty))
        for (index, digi) in frame.via.enumerated() {
            data.append(AX25.encodeAddress(digi, isLast: index == frame.via.count - 1))
        }
        data.append(frame.control)
        if let pid = frame.pid { data.append(pid) }
        data.append(frame.info)
        return data
    }

    /// One random mutation of a frame: bit flip, truncation, insertion,
    /// deletion, an extension bit set or cleared, or a control byte swap.
    static func mutate(_ input: Data, _ rng: inout PropertyRNG) -> Data {
        var data = input
        guard !data.isEmpty else { return rng.bytes(rng.int(in: 1...20)) }
        switch rng.int(7) {
        case 0:
            let i = rng.int(data.count)
            data[data.startIndex + i] ^= UInt8(1 << rng.int(8))
        case 1:
            data = data.prefix(rng.int(data.count))
        case 2:
            let i = rng.int(data.count + 1)
            data.insert(contentsOf: rng.bytes(rng.int(in: 1...16)), at: data.startIndex + i)
        case 3:
            let i = rng.int(data.count)
            data.remove(at: data.startIndex + i)
        case 4:
            // Toggle the extension bit of a random address slot.
            let slot = rng.int(max(1, min(10, data.count / 7)))
            let i = slot * 7 + 6
            if i < data.count { data[data.startIndex + i] ^= 0x01 }
        case 5:
            // Set bit 0 inside a callsign byte.
            let i = rng.int(min(data.count, 70))
            data[data.startIndex + i] |= 0x01
        default:
            // Replace the byte after the address field guess with any control.
            let i = min(data.count - 1, 14 + 7 * rng.int(3))
            data[data.startIndex + i] = rng.byte()
        }
        return data
    }

    /// One address slot with a valid callsign and a chosen extension bit.
    static func addressSlot(_ rng: inout PropertyRNG, last: Bool) -> Data {
        AX25.encodeAddress(address(&rng), isLast: last)
    }
}

// MARK: - Reference KISS deframer

/// The KISS framing rules written out plainly, to compare the streaming
/// parser against. Escapes follow AXTerm's current rule: a FESC followed by
/// anything but TFEND/TFESC is kept as is (see K5).
nonisolated enum ReferenceKISS {
    static func unescape(_ data: Data) -> Data {
        var out = Data()
        var bytes = Array(data)[...]
        while let byte = bytes.popFirst() {
            if byte == KISS.FESC, let next = bytes.first {
                if next == KISS.TFEND { out.append(KISS.FEND); bytes.removeFirst(); continue }
                if next == KISS.TFESC { out.append(KISS.FESC); bytes.removeFirst(); continue }
            }
            out.append(byte)
        }
        return out
    }

    static func frames(_ stream: Data) -> [KISSParsedFrame] {
        var result: [KISSParsedFrame] = []
        var current: Data? = nil
        for byte in stream {
            if byte == KISS.FEND {
                if let body = current, !body.isEmpty { result.append(contentsOf: process(body)) }
                current = Data()
            } else if current != nil {
                current!.append(byte)
            }
        }
        return result
    }

    private static func process(_ body: Data) -> [KISSParsedFrame] {
        // The escapes cover the command byte too (port 12's data command
        // is the FEND value).
        let unescaped = unescape(body)
        guard let command = unescaped.first else { return [] }
        let port = command >> 4
        let payload = Data(unescaped.dropFirst())
        switch command & 0x0F {
        case 0x00:
            return payload.isEmpty ? [] : [KISSParsedFrame(port: port, output: .ax25(payload))]
        case 0x06:
            return [KISSParsedFrame(port: port, output: .mobilinkdTelemetry(Data([command]) + payload))]
        default:
            return []
        }
    }
}

// MARK: - Tests

@MainActor
final class KISSAX25DecodePropertyTests: XCTestCase {

    private func feed(_ stream: Data, chunks: [Int]) -> [KISSParsedFrame] {
        var parser = KISSFrameParser()
        var out: [KISSParsedFrame] = []
        var offset = 0
        for size in chunks where offset < stream.count {
            let end = min(stream.count, offset + size)
            out += parser.feedFrames(stream.subdata(in: offset..<end))
            offset = end
        }
        if offset < stream.count { out += parser.feedFrames(stream.subdata(in: offset..<stream.count)) }
        return out
    }

    private func randomChunks(_ rng: inout PropertyRNG, total: Int) -> [Int] {
        var sizes: [Int] = []
        var left = total
        while left > 0 {
            let size = rng.chance(0.3) ? 1 : rng.int(in: 1...max(1, min(left, 97)))
            sizes.append(size)
            left -= size
        }
        return sizes
    }

    // K1
    func testKISSEscapeRoundTripsAnyPayload() {
        checkProperty("K1.escapeRoundTrip", cases: 400) { rng, v in
            let payload = rng.chance(0.5)
                ? AX25Gen.kissHeavyBytes(&rng, count: rng.int(in: 0...600))
                : rng.bytes(rng.int(in: 0...600))
            let escaped = KISS.escape(payload)
            v.check(!escaped.contains(KISS.FEND), "escaped payload contains FEND")
            v.check(KISS.unescape(escaped) == payload, "unescape(escape(x)) != x for \(payload.count) bytes")
            v.check(KISS.invalidEscapeCount(escaped) == 0, "a correctly escaped payload reports an invalid escape")
        }
    }

    // K2
    func testValidFrameStreamReassemblesAtEveryByteSplit() {
        checkProperty("K2.everyByteSplit", cases: 150) { rng, v in
            var stream = Data()
            // Noise before the first FEND is discarded by the parser.
            stream.append(contentsOf: rng.bytes(rng.int(in: 0...8)).filter { $0 != KISS.FEND })
            var expected: [KISSParsedFrame] = []
            for _ in 0..<rng.int(in: 1...4) {
                let frame = AX25Gen.validFrame(&rng, maxInfo: 40).bytes
                let port = UInt8(rng.int(16))
                stream.append(KISS.encodeFrame(payload: frame, port: port))
                expected.append(KISSParsedFrame(port: port, output: .ax25(frame)))
                // Back-to-back FENDs between frames are legal and common.
                if rng.chance(0.3) { stream.append(KISS.FEND) }
            }

            for split in 0...stream.count {
                let got = feed(stream, chunks: [split, stream.count - split])
                if got != expected {
                    v.record("split at byte \(split) of \(stream.count) gave \(got.count) frames, expected \(expected.count)")
                    break
                }
            }
            v.check(feed(stream, chunks: Array(repeating: 1, count: stream.count)) == expected,
                    "byte-at-a-time feed differs")
            v.check(feed(stream, chunks: randomChunks(&rng, total: stream.count)) == expected,
                    "random chunking differs")
        }
    }

    // K2 at full frame sizes, random partitions only.
    func testLongFrameStreamsSurviveRandomChunking() {
        checkProperty("K2.randomChunksLongFrames", cases: 200) { rng, v in
            var stream = Data()
            var expected: [KISSParsedFrame] = []
            for _ in 0..<rng.int(in: 1...6) {
                let frame = AX25Gen.validFrame(&rng).bytes
                let port = UInt8(rng.int(16))
                stream.append(KISS.encodeFrame(payload: frame, port: port))
                expected.append(KISSParsedFrame(port: port, output: .ax25(frame)))
            }
            for _ in 0..<4 {
                let got = feed(stream, chunks: randomChunks(&rng, total: stream.count))
                v.check(got == expected, "random chunking of \(stream.count) bytes gave \(got.count) of \(expected.count) frames")
            }
        }
    }

    // K3
    func testArbitraryStreamsMatchTheReferenceDeframer() {
        checkProperty("K3.referenceDeframer", cases: 400) { rng, v in
            let stream = AX25Gen.kissHeavyBytes(&rng, count: rng.int(in: 0...1500))
            let reference = ReferenceKISS.frames(stream)
            let whole = feed(stream, chunks: [stream.count])
            let chunked = feed(stream, chunks: randomChunks(&rng, total: stream.count))
            v.check(whole == reference, "parser (\(whole.count) frames) disagrees with reference (\(reference.count))")
            v.check(chunked == whole, "chunked feed differs from a single feed")
            for frame in whole {
                switch frame.output {
                case .ax25(let payload):
                    v.check(!payload.isEmpty, "empty DATA payload emitted")
                case .mobilinkdTelemetry:
                    break
                case .unknown:
                    v.record("parser emitted .unknown")
                }
            }
            // Deterministic: a second parser on the same bytes agrees.
            v.check(feed(stream, chunks: [stream.count]) == whole, "two parsers disagree on identical input")
        }
    }

    // K4
    func testOversizedAndUnterminatedFramesDoNotSwallowTheNextFrame() {
        checkProperty("K4.oversized", cases: 40) { rng, v in
            let real = AX25Gen.validFrame(&rng, maxInfo: 64).bytes
            var parser = KISSFrameParser()
            var out: [KISSParsedFrame] = []
            // An unterminated frame of up to 64 KiB, arriving in pieces.
            out += parser.feedFrames(Data([KISS.FEND, 0x00]))
            var giantBytes = 0
            for _ in 0..<rng.int(in: 1...16) {
                // No FEND (it would close the frame) and no FESC (it would
                // shorten it), so the frame's length is known exactly.
                let piece = rng.bytes(4096).map { $0 == KISS.FEND || $0 == KISS.FESC ? 0x41 : $0 }
                giantBytes += piece.count
                out += parser.feedFrames(Data(piece))
            }
            // Its closing FEND, then a real frame.
            out += parser.feedFrames(Data([KISS.FEND]) + KISS.encodeFrame(payload: real))
            v.check(out.count == 2, "expected the giant frame and the real one, got \(out.count) frames")
            if case .ax25(let payload)? = out.first?.output {
                v.check(payload.count == giantBytes,
                        "giant frame length \(payload.count) does not match \(giantBytes) bytes fed")
            } else {
                v.record("the giant frame was not emitted as DATA")
            }
            v.check(out.last?.output == .ax25(real), "the real frame after the giant one was lost or altered")
            v.check(AX25.decodeFrame(ax25: real) != nil, "precondition: the real frame decodes")
        }
    }

    // K5
    func testInvalidEscapesAreDetected() {
        checkProperty("K5.invalidEscapes", cases: 300) { rng, v in
            let valid = rng.bytes(rng.int(in: 0...100))
            var escaped = KISS.escape(valid)
            var planted = 0
            for _ in 0..<rng.int(in: 0...4) {
                let bad = UInt8(rng.int(256))
                guard bad != KISS.TFEND, bad != KISS.TFESC, bad != KISS.FEND, bad != KISS.FESC else { continue }
                // Insert between whole escape sequences only.
                var cut = rng.int(escaped.count + 1)
                while cut > 0, cut <= escaped.count, escaped[cut - 1] == KISS.FESC { cut -= 1 }
                escaped.insert(contentsOf: [KISS.FESC, bad], at: cut)
                planted += 1
            }
            let trailing = rng.chance(0.3)
            if trailing { escaped.append(KISS.FESC); planted += 1 }
            v.check(KISS.invalidEscapeCount(escaped) == planted,
                    "planted \(planted) invalid escapes, counted \(KISS.invalidEscapeCount(escaped))")
            // The bytes themselves are kept, as the KISS spec's "no action
            // is taken" reads, so the frame still reaches the AX.25 decoder
            // (and its fault, if any, is logged there).
            v.check(KISS.unescape(escaped).count == valid.count + planted * 2 - (trailing ? 1 : 0),
                    "unescape changed the length of a frame with invalid escapes unexpectedly")
        }
    }

    // A1
    func testValidFramesRoundTripByteIdentically() {
        checkProperty("A1.roundTrip", cases: 600) { rng, v in
            let (bytes, expected) = AX25Gen.validFrame(&rng)
            guard case .success(let frame) = AX25.checkFrame(ax25: bytes) else {
                v.record("valid \(expected.frameType) frame refused: \(AX25.decodeFailureReason(ax25: bytes))")
                return
            }
            v.check(frame.to?.call == expected.to.call && frame.to?.ssid == expected.to.ssid, "destination changed")
            v.check(frame.from?.call == expected.from.call && frame.from?.ssid == expected.from.ssid, "source changed")
            v.check(frame.via.map(\.call) == expected.via.map(\.call)
                    && frame.via.map(\.ssid) == expected.via.map(\.ssid), "digipeaters changed")
            v.check(frame.control == expected.control, "control 0x\(String(frame.control, radix: 16)) != 0x\(String(expected.control, radix: 16))")
            v.check(frame.pid == expected.pid, "pid changed")
            v.check(frame.info == expected.info, "info changed (\(frame.info.count) vs \(expected.info.count) bytes)")
            v.check(frame.frameType == expected.frameType, "frame type \(frame.frameType) != \(expected.frameType)")
            v.check(AX25Gen.reencode(frame) == bytes, "re-encoding is not byte-identical")

            // Through KISS on a random port.
            let port = UInt8(rng.int(16))
            var parser = KISSFrameParser()
            let out = parser.feedFrames(KISS.encodeFrame(payload: bytes, port: port))
            v.check(out == [KISSParsedFrame(port: port, output: .ax25(bytes))], "KISS round trip changed the frame")
        }
    }

    // A1 for the frames the session layer actually builds, C bits included.
    func testSessionBuiltFramesDecodeWithTheirCommandBit() {
        checkProperty("A1.builderRoundTrip", cases: 400) { rng, v in
            let to = AX25Gen.address(&rng), from = AX25Gen.address(&rng)
            let path = DigiPath((0..<rng.int(in: 0...8)).map { _ in AX25Gen.address(&rng) })
            let nr = rng.int(8), ns = rng.int(8), pf = rng.chance(0.5), cmd = rng.chance(0.5)
            let payload = rng.bytes(AX25Gen.infoLength(&rng))
            let frame: OutboundFrame
            switch rng.int(9) {
            case 0: frame = AX25FrameBuilder.buildIFrame(from: from, to: to, via: path, ns: ns, nr: nr, payload: payload, pf: pf)
            case 1: frame = AX25FrameBuilder.buildRR(from: from, to: to, via: path, nr: nr, pf: pf, isCommand: cmd)
            case 2: frame = AX25FrameBuilder.buildRNR(from: from, to: to, via: path, nr: nr, pf: pf, isCommand: cmd)
            case 3: frame = AX25FrameBuilder.buildREJ(from: from, to: to, via: path, nr: nr, pf: pf, isCommand: cmd)
            case 4: frame = AX25FrameBuilder.buildSREJ(from: from, to: to, via: path, nr: nr, pf: pf, isCommand: cmd)
            case 5: frame = AX25FrameBuilder.buildSABM(from: from, to: to, via: path, pf: pf)
            case 6: frame = AX25FrameBuilder.buildDISC(from: from, to: to, via: path, pf: pf)
            case 7: frame = AX25FrameBuilder.buildUA(from: from, to: to, via: path, pf: pf)
            default: frame = AX25FrameBuilder.buildDM(from: from, to: to, via: path, pf: pf)
            }
            let bytes = frame.encodeAX25()
            guard case .success(let decoded) = AX25.checkFrame(ax25: bytes) else {
                v.record("built \(frame.displayInfo ?? frame.frameType) refused: \(AX25.decodeFailureReason(ax25: bytes))")
                return
            }
            let decodedCommand = decoded.isCommand == true
            let decodedResponse = decoded.isCommand == false
            v.check(decodedCommand || decodedResponse, "C bits are not a v2 command/response pair")
            v.check(decodedCommand == (frame.isCommand ?? true), "command bit lost: built \(String(describing: frame.isCommand))")
            v.check(decoded.control == frame.controlByte, "control byte changed")
            v.check((decoded.control & 0x10 != 0) == pf, "P/F bit changed")
            if frame.frameType == "i" {
                v.check(decoded.info == payload && decoded.pid == 0xF0, "I-frame info or pid changed")
            } else {
                v.check(decoded.info.isEmpty, "S/U frame grew an info field")
            }
            v.check(decoded.via.count == path.digis.count, "digipeater count changed")
        }
    }

    // A2
    func testDecodingIsTotalAndDeterministic() {
        checkProperty("A2.totalDeterministic", cases: 1500) { rng, v in
            let input: Data
            switch rng.int(3) {
            case 0: input = rng.bytes(rng.int(in: 0...400))
            case 1:
                var data = AX25Gen.validFrame(&rng, maxInfo: 300).bytes
                for _ in 0..<rng.int(in: 1...4) { data = AX25Gen.mutate(data, &rng) }
                input = data
            default:
                // Plausible address fields with random extension bits.
                var data = Data()
                for _ in 0..<rng.int(in: 1...12) {
                    data.append(AX25Gen.addressSlot(&rng, last: rng.chance(0.2)))
                }
                data.append(rng.bytes(rng.int(in: 0...6)))
                input = data
            }

            let first = AX25.checkFrame(ax25: input)
            let second = AX25.checkFrame(ax25: input)
            // A slice with a non-zero startIndex must decode the same way.
            let padded = rng.bytes(rng.int(in: 1...9)) + input
            let slice = padded.suffix(input.count)
            let fromSlice = AX25.checkFrame(ax25: slice)

            switch (first, second, fromSlice) {
            case (.failure(let a), .failure(let b), .failure(let c)):
                v.check(a == b && a == c, "fault differs between runs or for a slice: \(a) / \(b) / \(c)")
                v.check(!a.reason.isEmpty && !a.summary.isEmpty, "refusal without a reason")
                v.check(AX25.decodeFailureReason(ax25: input) == a.reason, "decodeFailureReason disagrees with checkFrame")
                v.check(AX25.decodeFrame(ax25: input) == nil, "decodeFrame accepted what checkFrame refused")
            case (.success(let a), .success(let b), .success(let c)):
                v.check(Self.same(a, b) && Self.same(a, c), "decode differs between runs or for a slice")
                Self.checkAccepted(a, bytes: input, v)
            default:
                v.record("checkFrame changed its verdict between runs or for a slice")
            }
        }
    }

    // A3
    func testExtensionBitPlacementDecidesTheOutcome() {
        checkProperty("A3.extensionBits", cases: 800) { rng, v in
            let slots = rng.int(in: 3...12)
            // The first slot whose SSID byte ends the field; nil for none.
            let endAt: Int? = rng.chance(0.15) ? nil : rng.int(slots)
            let withControl = rng.chance(0.85)
            var data = Data()
            for slot in 0..<slots {
                data.append(AX25Gen.addressSlot(&rng, last: slot == endAt))
            }
            let trailingAfterEnd = endAt.map { (slots - 1 - $0) * 7 } ?? 0
            if withControl { data.append(0x03); data.append(0xF0) }
            let result = AX25.checkFrame(ax25: data)

            switch endAt {
            case 0?:
                v.check(result.failureValue == .endsAfterDestination, "extension bit on destination gave \(result)")
            case let end? where end <= 9:
                // Slots after the end are trailing bytes; they become the
                // control/PID/info of the frame. The frame is valid when
                // anything at all follows the address field.
                if trailingAfterEnd > 0 || withControl {
                    if case .success(let frame) = result {
                        v.check(frame.via.count == end - 1, "end at slot \(end) gave \(frame.via.count) digipeaters")
                    } else {
                        v.record("end at slot \(end) refused: \(result)")
                    }
                } else {
                    v.check(result.failureValue == .missingControlField, "no control byte gave \(result)")
                }
            case _?:
                v.check(result.failureValue == .tooManyDigipeaters, "end at slot \(endAt!) gave \(result)")
            case nil:
                if slots >= 10 {
                    v.check(result.failureValue == .tooManyDigipeaters, "no end in \(slots) slots gave \(result)")
                } else {
                    // Two trailing control/PID bytes are not a full address,
                    // so the field runs out either way.
                    v.check(result.failureValue == .unterminatedAddressField(addresses: slots),
                            "no end in \(slots) slots gave \(result)")
                }
            }
        }
    }

    // A5: every control byte, with and without a PID and info, decodes the
    // same way through both decoders, and S and U frames keep any info
    // bytes they carry (AXTerm accepts them; see AX25PropertyFindingsTests).
    func testEveryControlByteClassifiesConsistently() {
        checkProperty("A5.controlPidCombos", cases: 200) { rng, v in
            let to = AX25Gen.address(&rng), from = AX25Gen.address(&rng)
            let via = (0..<rng.int(in: 0...8)).map { _ in AX25Gen.address(&rng) }
            let trailer = rng.bytes(rng.pick([0, 1, 2, rng.int(in: 3...300)]))
            for control in UInt8.min...UInt8.max {
                var bytes = Data()
                bytes.append(AX25.encodeAddress(to, isLast: false))
                bytes.append(AX25.encodeAddress(from, isLast: via.isEmpty))
                for (index, digi) in via.enumerated() {
                    bytes.append(AX25.encodeAddress(digi, isLast: index == via.count - 1))
                }
                bytes.append(control)
                bytes.append(trailer)
                guard case .success(let frame) = AX25.checkFrame(ax25: bytes) else {
                    v.record(String(format: "control 0x%02X refused: ", control) + AX25.decodeFailureReason(ax25: bytes))
                    return
                }
                let decoded = AX25ControlFieldDecoder.decode(control: control, controlByte1: nil)
                let agrees: Bool
                switch frame.frameType {
                case .i: agrees = decoded.frameClass == .I
                case .s: agrees = decoded.frameClass == .S
                case .u: agrees = decoded.frameClass == .U && decoded.uType != .UI
                case .ui: agrees = decoded.frameClass == .U && decoded.uType == .UI
                case .unknown: agrees = false
                }
                v.check(agrees, String(format: "control 0x%02X: frame type %@ but control decoder says %@ %@",
                                       control, frame.frameType.rawValue, decoded.frameClass.rawValue,
                                       decoded.uType?.rawValue ?? decoded.sType?.rawValue ?? ""))
                if frame.frameType == .i || frame.frameType == .ui {
                    v.check(frame.pid == trailer.first && frame.info == trailer.dropFirst(),
                            String(format: "control 0x%02X: PID/info split wrong", control))
                } else {
                    v.check(frame.pid == nil && frame.info == trailer,
                            String(format: "control 0x%02X: S/U frame lost or split its info bytes", control))
                }
                if !v.isEmpty { return }
            }
        }
    }

    // A4
    func testEveryUndecodableFrameIsLoggedOnce() {
        checkProperty("A4.malformedLogged", cases: 30) { rng, v in
            let logger = MockEventLogger()
            let defaults = TestDefaults.make("KISSAX25DecodePropertyTests")
            defaults.set(false, forKey: AppSettingsStore.persistKey)
            let engine = PacketEngine(
                maxPackets: 500, maxConsoleLines: 10, maxRawChunks: 10,
                settings: AppSettingsStore(defaults: defaults),
                packetStore: nil, consoleStore: nil, rawStore: nil,
                eventLogger: logger)

            var refused = 0
            for _ in 0..<rng.int(in: 5...25) {
                var frame = AX25Gen.validFrame(&rng, maxInfo: 80).bytes
                if rng.chance(0.6) {
                    for _ in 0..<rng.int(in: 1...3) { frame = AX25Gen.mutate(frame, &rng) }
                }
                guard !frame.isEmpty else { continue }
                if AX25.decodeFrame(ax25: frame) == nil { refused += 1 }
                engine.handleIncomingData(KISS.encodeFrame(payload: frame))
            }
            let warnings = logger.entries.filter {
                $0.0 == .warning && $0.1 == .parser && $0.2 == "Failed to decode AX.25 frame"
            }
            v.check(warnings.count == refused, "\(refused) frames refused, \(warnings.count) logged")
            v.check(warnings.allSatisfy { !($0.3?["reason"] ?? "").isEmpty }, "a logged refusal has no reason")
        }
    }

    // MARK: - Helpers

    private static func same(_ a: AX25.FrameDecodeResult, _ b: AX25.FrameDecodeResult) -> Bool {
        a.to == b.to && a.from == b.from && a.via == b.via && a.control == b.control
            && a.pid == b.pid && a.info == b.info && a.frameType == b.frameType
    }

    /// The fields of an accepted frame must agree with its bytes.
    private static func checkAccepted(_ frame: AX25.FrameDecodeResult, bytes: Data, _ v: PropertyViolations) {
        let raw = Array(bytes)
        v.check(frame.via.count <= 8, "\(frame.via.count) digipeaters accepted")
        let header = 14 + 7 * frame.via.count
        v.check(raw.count > header, "accepted frame has no control byte")
        guard raw.count > header else { return }
        for slot in 0..<(2 + frame.via.count) {
            let ext = raw[slot * 7 + 6] & 0x01
            v.check(ext == (slot == 1 + frame.via.count ? 1 : 0), "extension bit wrong in accepted slot \(slot)")
            for i in 0..<6 { v.check(raw[slot * 7 + i] & 0x01 == 0, "callsign byte with bit 0 set accepted") }
        }
        for address in [frame.to, frame.from].compactMap({ $0 }) + frame.via {
            v.check(!address.call.isEmpty && address.call.count <= 6
                    && address.call.allSatisfy({ AX25Gen.callsignAlphabet.contains($0) }),
                    "accepted callsign \(address.call)")
            v.check((0...15).contains(address.ssid), "accepted SSID \(address.ssid)")
        }
        v.check(frame.control == raw[header], "control is not the byte after the address field")
        v.check(frame.frameType == AX25.classifyFrameType(control: frame.control), "frame type disagrees with control")
        var rest = Array(raw[(header + 1)...])
        if frame.frameType == .i || frame.frameType == .ui, !rest.isEmpty {
            v.check(frame.pid == rest.removeFirst(), "pid is not the byte after control")
        } else {
            v.check(frame.pid == nil, "pid on a frame type without one")
        }
        v.check(Array(frame.info) == rest, "info is not the remaining bytes")
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
