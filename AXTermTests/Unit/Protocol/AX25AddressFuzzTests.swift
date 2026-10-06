//
//  AX25AddressFuzzTests.swift
//  AXTermTests
//
//  Property tests for the strict address rules. Every test is seeded, so a
//  failure names its seed and iteration and reproduces exactly.
//
//  Two references are checked against the decoder:
//
//  - `AddressOracle` restates the rules a different way, the way Direwolf
//    finds an address field: the field ends at the first byte with bit 0 set,
//    must be a whole number of 7-byte addresses, 2 to 10 of them, and each
//    callsign must trim to 1-6 of A-Z/0-9. The decoder must accept exactly
//    the frames the oracle accepts, and read them the same way.
//  - `LegacyDecoder` is the decoder as it was before the rules. Anything the
//    new decoder accepts must come out byte-for-byte as the old one read it,
//    so the rules can only ever remove frames, never change one.
//

import XCTest
@testable import AXTerm

final class AX25AddressFuzzTests: XCTestCase {

    // MARK: - Independent oracle

    struct OracleAddress: Equatable {
        let call: String
        let ssid: Int
        let hBit: Bool
    }

    struct OracleFrame {
        let addresses: [OracleAddress]
        let controlIndex: Int
    }

    enum AddressOracle {
        private static let legal: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

        static func parse(_ bytes: [UInt8]) -> OracleFrame? {
            guard bytes.count >= 15 else { return nil }
            guard let end = bytes.firstIndex(where: { $0 & 1 == 1 }) else { return nil }
            let fieldLength = end + 1
            guard fieldLength % 7 == 0 else { return nil }
            let count = fieldLength / 7
            guard (2...10).contains(count), fieldLength < bytes.count else { return nil }

            var addresses: [OracleAddress] = []
            for n in 0..<count {
                let chunk = bytes[(n * 7)..<(n * 7 + 7)]
                let text = String(chunk.prefix(6).map { Character(UnicodeScalar($0 >> 1)) })
                var trimmed = Substring(text)
                while trimmed.last == " " { trimmed = trimmed.dropLast() }
                guard !trimmed.isEmpty, trimmed.allSatisfy({ legal.contains($0) }) else { return nil }
                let ssidByte = chunk.last!
                addresses.append(OracleAddress(call: String(trimmed),
                                               ssid: Int(ssidByte >> 1) & 0x0F,
                                               hBit: ssidByte & 0x80 != 0))
            }
            return OracleFrame(addresses: addresses, controlIndex: fieldLength)
        }

        static func isValidCallsign(_ call: String) -> Bool {
            (1...6).contains(call.count) && call.allSatisfy { legal.contains($0) }
        }
    }

    // MARK: - The decoder as it was before the address rules

    enum LegacyDecoder {
        struct Frame: Equatable {
            let to: AX25Address
            let from: AX25Address
            let via: [AX25Address]
            let control: UInt8
            let pid: UInt8?
            let info: Data
        }

        private static func address(_ b: [UInt8], _ offset: Int) -> (AX25Address, Bool)? {
            guard offset + 7 <= b.count else { return nil }
            var chars: [Character] = []
            for i in 0..<6 {
                let c = b[offset + i] >> 1
                if c >= 0x20 && c < 0x7F && c != 0x20 { chars.append(Character(UnicodeScalar(c))) }
            }
            guard !chars.isEmpty else { return nil }
            let s = b[offset + 6]
            return (AX25Address(call: String(chars), ssid: Int((s >> 1) & 0x0F), repeated: s & 0x80 != 0),
                    s & 0x01 != 0)
        }

        static func decode(_ b: [UInt8]) -> Frame? {
            guard b.count >= 15, let (to, _) = address(b, 0), let (from, srcLast) = address(b, 7) else {
                return nil
            }
            var via: [AX25Address] = []
            var offset = 14
            var last = srcLast
            while !last && offset + 7 <= b.count && via.count < 8 {
                guard let (v, l) = address(b, offset) else { break }
                via.append(v); offset += 7; last = l
            }
            guard offset < b.count else { return nil }
            let control = b[offset]; offset += 1
            let type = AX25.classifyFrameType(control: control)
            var pid: UInt8?
            if (type == .i || type == .ui) && offset < b.count { pid = b[offset]; offset += 1 }
            return Frame(to: to, from: from, via: via, control: control, pid: pid,
                         info: Data(b[offset...]))
        }
    }

    // MARK: - Checks shared by every property

    /// Decoder accepts iff the oracle does; on accept, every field agrees with
    /// the oracle and with the legacy decoder, and every callsign is legal.
    private func assertAgreement(_ bytes: [UInt8], _ context: @autoclosure () -> String,
                                 file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let decoded = AX25.decodeFrame(ax25: Data(bytes))
        let oracle = AddressOracle.parse(bytes)
        guard let decoded else {
            if oracle != nil {
                XCTFail("decoder refused a frame the oracle accepts (\(AX25.decodeFailureReason(ax25: Data(bytes)))): "
                        + "\(context()) \(hex(bytes))", file: file, line: line)
            }
            // A refused frame always has a reason to log.
            XCTAssertFalse(AX25.decodeFailureReason(ax25: Data(bytes)).hasPrefix("no fault"),
                           context(), file: file, line: line)
            return false
        }
        guard let oracle else {
            XCTFail("decoder accepted a frame the oracle refuses: \(context()) \(hex(bytes))",
                    file: file, line: line)
            return true
        }
        let all = [decoded.to!, decoded.from!] + decoded.via
        // Bit 7 is the H bit only on a digipeater; on the destination and
        // source it is the C bit, which the decoder reports as `isCommand`.
        let expected = oracle.addresses.enumerated().map { index, address in
            index < 2 ? OracleAddress(call: address.call, ssid: address.ssid, hBit: false) : address
        }
        XCTAssertEqual(all.map { OracleAddress(call: $0.call, ssid: $0.ssid, hBit: $0.repeated) },
                       expected, context(), file: file, line: line)
        let destC = oracle.addresses[0].hBit, srcC = oracle.addresses[1].hBit
        XCTAssertEqual(decoded.isCommand, destC == srcC ? nil : destC, context(), file: file, line: line)
        XCTAssertEqual(decoded.control, bytes[oracle.controlIndex], context(), file: file, line: line)
        for a in all where !AddressOracle.isValidCallsign(a.call) {
            XCTFail("accepted illegal callsign \(a.call): \(context())", file: file, line: line)
        }

        // The legacy decoder read the C bits into `repeated`; set those aside.
        let legacy = LegacyDecoder.decode(bytes).map {
            LegacyDecoder.Frame(to: AX25Address(call: $0.to.call, ssid: $0.to.ssid),
                                from: AX25Address(call: $0.from.call, ssid: $0.from.ssid),
                                via: $0.via, control: $0.control, pid: $0.pid, info: $0.info)
        }
        XCTAssertEqual(legacy, LegacyDecoder.Frame(to: decoded.to!, from: decoded.from!, via: decoded.via,
                                                   control: decoded.control, pid: decoded.pid,
                                                   info: decoded.info),
                       "legacy decoder disagrees: \(context())", file: file, line: line)
        return true
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - (a) Random bytes

    func testRandomBytesNeverCrashAndNeverYieldBadCallsigns() {
        let seed: UInt64 = 0xA25_0001
        var rng = SplitMix64(seed: seed)
        let iterations = 100_000
        var accepted = 0
        for i in 0..<iterations {
            let length = Int.random(in: 0...400, using: &rng)
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if assertAgreement(bytes, "seed=\(seed) i=\(i)") { accepted += 1 }
        }
        // Uniform noise essentially never forms two legal addresses; the
        // decoder should accept (almost) none of it. The old decoder accepted
        // a large share.
        XCTAssertLessThan(accepted, 5, "accepted \(accepted) of \(iterations) random frames")
    }

    func testLegacyDecoderWouldHaveAcceptedMuchOfTheSameNoise() {
        // Context for the test above: how often noise used to become a packet.
        var rng = SplitMix64(seed: 0xA25_0002)
        var legacyAccepted = 0
        var accepted = 0
        for _ in 0..<20_000 {
            let length = Int.random(in: 15...100, using: &rng)
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if LegacyDecoder.decode(bytes) != nil { legacyAccepted += 1 }
            if AX25.decodeFrame(ax25: Data(bytes)) != nil { accepted += 1 }
        }
        XCTAssertGreaterThan(legacyAccepted, 10_000)
        XCTAssertLessThan(accepted, 3)
    }

    /// Random frames built near the edge of the rules: mostly legal
    /// characters with occasional illegal ones, stray bit 0s, embedded
    /// spaces, random SSID bytes and extension bits in odd places. Unlike
    /// uniform noise, a real share of these is accepted, so both branches
    /// of the agreement check get exercised.
    func testNearMissFramesAgreeWithTheOracle() {
        let seed: UInt64 = 0xA25_0003
        var rng = SplitMix64(seed: seed)
        let legal = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
        let iterations = 100_000
        var accepted = 0
        for i in 0..<iterations {
            let count = Int.random(in: 1...11, using: &rng)
            var bytes: [UInt8] = []
            for n in 0..<count {
                let length = Int.random(in: 0...6, using: &rng)
                var chars: [UInt8] = (0..<length).map { _ in
                    Int.random(in: 0..<40, using: &rng) == 0
                        ? UInt8.random(in: 0...0x7F, using: &rng)
                        : legal.randomElement(using: &rng)!
                }
                chars += Array(repeating: 0x20, count: 6 - length)
                if Int.random(in: 0..<30, using: &rng) == 0 {
                    chars.swapAt(Int.random(in: 0..<6, using: &rng), Int.random(in: 0..<6, using: &rng))
                }
                var callBytes = chars.map { $0 << 1 }
                if Int.random(in: 0..<40, using: &rng) == 0 {
                    callBytes[Int.random(in: 0..<6, using: &rng)] |= 0x01
                }
                var ssid = UInt8.random(in: 0...255, using: &rng) & 0xFE
                let wantLast = n == count - 1
                if wantLast ? Int.random(in: 0..<30, using: &rng) != 0 : Int.random(in: 0..<60, using: &rng) == 0 {
                    ssid |= 0x01
                }
                bytes += callBytes + [ssid]
            }
            bytes += (0..<Int.random(in: 0...12, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            if assertAgreement(bytes, "seed=\(seed) i=\(i)") { accepted += 1 }
        }
        XCTAssertGreaterThan(accepted, iterations / 10, "too few accepted to exercise the accept path")
        XCTAssertLessThan(accepted, iterations * 9 / 10, "too few refused to exercise the refuse path")
    }

    // MARK: - (b) Mutated real frames

    func testMutatedRealFramesAgreeWithTheOracle() throws {
        let corpus = AX25AddressCorpusTests.corpusFrames.map { [UInt8]($0) }
        XCTAssertGreaterThan(corpus.count, 100)
        let seed: UInt64 = 0xA25_0004
        var rng = SplitMix64(seed: seed)
        let iterations = 100_000
        var accepted = 0
        for i in 0..<iterations {
            let index = Int.random(in: 0..<corpus.count, using: &rng)
            var bytes = corpus[index]
            let fieldLength = (bytes.firstIndex { $0 & 1 == 1 } ?? 13) + 1
            switch Int.random(in: 0..<4, using: &rng) {
            case 0:  // one bit
                let at = Int.random(in: 0..<fieldLength, using: &rng)
                bytes[at] ^= 1 << UInt8.random(in: 0...7, using: &rng)
            case 1:  // a few bits
                for _ in 0..<Int.random(in: 2...4, using: &rng) {
                    let at = Int.random(in: 0..<fieldLength, using: &rng)
                    bytes[at] ^= 1 << UInt8.random(in: 0...7, using: &rng)
                }
            case 2:  // one whole byte
                bytes[Int.random(in: 0..<fieldLength, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            default:  // truncate inside or just after the address field
                bytes = Array(bytes.prefix(Int.random(in: 0...(fieldLength + 1), using: &rng)))
            }
            if assertAgreement(bytes, "seed=\(seed) i=\(i) corpus[\(index)]") { accepted += 1 }
        }
        XCTAssertGreaterThan(accepted, 1_000)
        XCTAssertLessThan(accepted, iterations - 1_000)
    }

    func testEverySingleBitFlipInEveryRealAddressField() throws {
        // Exhaustive rather than random: each corpus frame, each bit of its
        // address field.
        var flips = 0
        for (index, frame) in AX25AddressCorpusTests.corpusFrames.enumerated() {
            let original = [UInt8](frame)
            let fieldLength = (original.firstIndex { $0 & 1 == 1 } ?? 13) + 1
            for at in 0..<fieldLength {
                for bit in 0..<8 {
                    var bytes = original
                    bytes[at] ^= 1 << bit
                    _ = assertAgreement(bytes, "corpus[\(index)] byte \(at) bit \(bit)")
                    flips += 1
                }
            }
        }
        XCTAssertGreaterThan(flips, 20_000)
    }

    // MARK: - (c) Round trip through AXTerm's own encoders

    private func randomAddress(_ rng: inout SplitMix64, repeated: Bool = false) -> AX25Address {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let length = Int.random(in: 1...6, using: &rng)
        let call = String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
        return AX25Address(call: call, ssid: Int.random(in: 0...15, using: &rng), repeated: repeated)
    }

    func testRandomValidAddressesRoundTripThroughEveryEncoder() throws {
        let seed: UInt64 = 0xA25_0005
        var rng = SplitMix64(seed: seed)
        let iterations = 25_000
        for i in 0..<iterations {
            let ctx = "seed=\(seed) i=\(i)"
            let to = randomAddress(&rng)
            let from = randomAddress(&rng)
            let digiCount = Int.random(in: 0...8, using: &rng)
            let via = (0..<digiCount).map { _ in randomAddress(&rng, repeated: Bool.random(using: &rng)) }
            let info = Data((0..<Int.random(in: 0...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })

            let encoded: Data
            let expectRepeated: Bool
            switch Int.random(in: 0..<5, using: &rng) {
            case 0:
                encoded = AX25.encodeUIFrame(from: from, to: to, via: via, info: info)
                expectRepeated = false  // AX25.encodeAddress does not write the H bit
            case 1:
                encoded = AX25.encodeIFrame(from: from, to: to, via: via,
                                            ns: Int.random(in: 0...7, using: &rng),
                                            nr: Int.random(in: 0...7, using: &rng), info: info)
                expectRepeated = false
            case 2:
                encoded = AX25.encodeSFrame(from: from, to: to, via: via, type: .rr,
                                            nr: Int.random(in: 0...7, using: &rng))
                expectRepeated = false
            case 3:
                encoded = AX25.encodeUFrame(from: from, to: to, via: via, type: .sabm, pf: true)
                expectRepeated = false
            default:
                encoded = OutboundFrame(destination: to, source: from, path: DigiPath(via),
                                        payload: info).encodeAX25()
                expectRepeated = true
            }

            let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: encoded),
                                        "\(ctx): \(AX25.decodeFailureReason(ax25: encoded))")
            XCTAssertEqual(decoded.to?.call, to.call, ctx)
            XCTAssertEqual(decoded.to?.ssid, to.ssid, ctx)
            XCTAssertEqual(decoded.from?.call, from.call, ctx)
            XCTAssertEqual(decoded.from?.ssid, from.ssid, ctx)
            XCTAssertEqual(decoded.via.map(\.call), via.map(\.call), ctx)
            XCTAssertEqual(decoded.via.map(\.ssid), via.map(\.ssid), ctx)
            if expectRepeated {
                XCTAssertEqual(decoded.via.map(\.repeated), via.map(\.repeated), ctx)
            }
            _ = assertAgreement([UInt8](encoded), ctx)
        }
    }

    // MARK: - (d) Noise through the KISS parser

    func testNoiseThroughTheKISSParserNeverBecomesABadStation() {
        let seed: UInt64 = 0xA25_0006
        var rng = SplitMix64(seed: seed)
        var parser = KISSFrameParser()
        var frames = 0
        for i in 0..<5_000 {
            // Noise with FENDs sprinkled in, the shape of an open squelch on a
            // TNC that lets frames through.
            let chunk = (0..<Int.random(in: 1...512, using: &rng)).map { _ -> UInt8 in
                Int.random(in: 0..<40, using: &rng) == 0 ? KISS.FEND : UInt8.random(in: 0...255, using: &rng)
            }
            for output in parser.feed(Data(chunk)) {
                guard case .ax25(let payload) = output else { continue }
                frames += 1
                _ = assertAgreement([UInt8](payload), "seed=\(seed) chunk=\(i)")
            }
        }
        // Only command nibble 0 is a data frame, so about 1 in 16 of these.
        XCTAssertGreaterThan(frames, 1_000)
    }

    // MARK: - Speed

    func testDecodingTheCorpusStaysFast() {
        // The rules run on every received frame. 100k decodes of real frames
        // should take well under a second even in a debug build.
        let corpus = AX25AddressCorpusTests.corpusFrames
        let start = Date()
        var decoded = 0
        for i in 0..<100_000 where AX25.decodeFrame(ax25: corpus[i % corpus.count]) != nil {
            decoded += 1
        }
        XCTAssertEqual(decoded, 100_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
    }
}
