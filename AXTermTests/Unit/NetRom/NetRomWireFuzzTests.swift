import XCTest
@testable import AXTerm

/// Deterministic RNG for reproducible fuzzing. SplitMix64: tiny, seedable,
/// and good enough to explore the input space. Every failure message
/// carries the seed so a run can be replayed exactly.
nonisolated struct NetRomFuzzRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    mutating func int(_ range: Range<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
    mutating func data(count: Int) -> Data { Data((0..<count).map { _ in byte() }) }
}

final class NetRomWireFuzzTests: XCTestCase {

    private let calls = ["K0EPI", "KB5YZB", "W0ARP", "N0X", "AB0VZ", "K0NTS", "WH6ANH", "A1A"]

    private func randomAddress(_ rng: inout NetRomFuzzRNG) -> AX25Address {
        AX25Address(call: calls[rng.int(0..<calls.count)], ssid: rng.int(0..<16))
    }

    // MARK: - Totality: arbitrary bytes never crash the parser

    func testParserIsTotalOverRandomBlobs() {
        var rng = NetRomFuzzRNG(seed: 0xA0EF1)
        for i in 0..<20_000 {
            let blob = rng.data(count: rng.int(0..<300))
            // The only requirement is "does not trap". Parse result is free.
            _ = NetRomTransportWire.parse(blob)
            if i % 5000 == 0 { XCTAssertTrue(true) }  // keep the runner honest
        }
    }

    // MARK: - Mutation: valid frames with bytes flipped never crash,
    // and a surviving parse re-encodes without trapping.

    func testMutatedValidFramesNeverCrash() {
        var rng = NetRomFuzzRNG(seed: 0xBADF00D)
        for _ in 0..<4_000 {
            var bytes = [UInt8](NetRomTransportWire.encode(randomDatagram(&rng)))
            for _ in 0..<rng.int(1..<6) {
                let index = rng.int(0..<bytes.count)
                bytes[index] = rng.byte()
            }
            if rng.chance(0.3) {
                bytes = Array(bytes.prefix(rng.int(0..<bytes.count + 1)))
            }
            if let parsed = NetRomTransportWire.parse(Data(bytes)) {
                _ = NetRomTransportWire.encode(parsed)
            }
        }
    }

    // MARK: - Property: encode → parse is the identity on valid frames

    func testRandomValidFramesRoundTrip() {
        var rng = NetRomFuzzRNG(seed: 0xC0FFEE)
        for iteration in 0..<4_000 {
            let datagram = randomDatagram(&rng)
            let encoded = NetRomTransportWire.encode(datagram)
            guard let parsed = NetRomTransportWire.parse(encoded) else {
                return XCTFail("iteration \(iteration): valid frame failed to parse: \(datagram)")
            }
            XCTAssertEqual(parsed, datagram, "iteration \(iteration) (seed 0xC0FFEE)")
        }
    }

    // MARK: - Property: parse → encode → parse is stable on anything
    // the parser accepts (semantic fixpoint after one normalization).

    func testParseEncodeParseIsStable() {
        var rng = NetRomFuzzRNG(seed: 0x5EED)
        var accepted = 0
        for _ in 0..<30_000 {
            // Bias toward parseable inputs: half random blobs, half
            // valid frames with light mutation.
            var bytes: [UInt8]
            if rng.chance(0.5) {
                bytes = [UInt8](rng.data(count: rng.int(20..<80)))
            } else {
                bytes = [UInt8](NetRomTransportWire.encode(randomDatagram(&rng)))
                if rng.chance(0.5) { bytes[rng.int(0..<bytes.count)] = rng.byte() }
            }
            guard let first = NetRomTransportWire.parse(Data(bytes)) else { continue }
            accepted += 1
            let reencoded = NetRomTransportWire.encode(first)
            guard let second = NetRomTransportWire.parse(reencoded) else {
                return XCTFail("re-encode of an accepted frame must re-parse: \(first)")
            }
            XCTAssertEqual(first, second, "normalization must be a fixpoint")
        }
        XCTAssertGreaterThan(accepted, 1_000, "the corpus should actually exercise accepts")
    }

    // MARK: - Random valid frame generator

    private func randomDatagram(_ rng: inout NetRomFuzzRNG) -> NetRomDatagram {
        NetRomDatagram(
            origin: randomAddress(&rng),
            destination: randomAddress(&rng),
            ttl: UInt8(rng.int(1..<256)),
            transport: randomFrame(&rng)
        )
    }

    private func randomFrame(_ rng: inout NetRomFuzzRNG) -> NetRomL4Frame {
        switch rng.int(0..<8) {
        case 0:
            return .connectRequest(
                myIndex: rng.byte(), myId: rng.byte(),
                proposedWindow: rng.byte(),
                user: randomAddress(&rng), originNode: randomAddress(&rng),
                t1Seconds: rng.chance(0.5) ? UInt16(truncatingIfNeeded: rng.next()) : nil
            )
        case 1:
            // Constrain to shapes the parser preserves: the exotic
            // zero-index refusal is normalized on parse, so a random
            // refused frame with myIndex/myId == 0 and yourIndex/yourId
            // == 0 would not round-trip identically. Generate the
            // standard shape (as our encoder does).
            let refused = rng.chance(0.3)
            return .connectAck(
                yourIndex: UInt8(rng.int(1..<256)), yourId: UInt8(rng.int(1..<256)),
                myIndex: refused ? 0 : rng.byte(), myId: refused ? 0 : rng.byte(),
                acceptedWindow: rng.byte(),
                ttl: rng.chance(0.5) ? rng.byte() : nil,
                refused: refused
            )
        case 2:
            return .disconnectRequest(yourIndex: rng.byte(), yourId: rng.byte())
        case 3:
            return .disconnectAck(yourIndex: rng.byte(), yourId: rng.byte())
        case 4:
            return .information(
                yourIndex: rng.byte(), yourId: rng.byte(),
                txSeq: rng.byte(), rxSeq: rng.byte(),
                choke: rng.chance(0.2), nak: rng.chance(0.2), moreFollows: rng.chance(0.3),
                payload: rng.data(count: rng.int(0..<(NetRomWire.maxInfoPayload + 1)))
            )
        case 5:
            return .informationAck(
                yourIndex: rng.byte(), yourId: rng.byte(),
                rxSeq: rng.byte(),
                choke: rng.chance(0.2), nak: rng.chance(0.2)
            )
        case 6:
            return .reset(yourIndex: rng.byte(), yourId: rng.byte())
        default:
            // Protocol extension: 5 header bytes with opcode nibble 0,
            // plus opaque data.
            var raw: [UInt8] = [rng.byte(), rng.byte(), rng.byte(), rng.byte(),
                                rng.byte() & 0xF0]
            raw += [UInt8](rng.data(count: rng.int(0..<40)))
            return .protocolExtension(raw: Data(raw))
        }
    }
}
