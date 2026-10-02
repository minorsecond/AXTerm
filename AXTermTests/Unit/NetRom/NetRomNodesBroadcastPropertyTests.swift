//
//  NetRomNodesBroadcastPropertyTests.swift
//  AXTermTests
//
//  NODES broadcasts, the routing tables nodes send each other as UI frames.
//  The parser reads more than one layout (standard 21-byte entries, alias
//  first, origin alias), so it has to guess, and a wrong guess turns a
//  neighbor's table into nonsense routes. Seeded properties:
//
//  - any payload parses without trapping;
//  - whatever AXTerm's encoder sends, the parser reads back exactly:
//    every destination, alias, best neighbor and quality.
//

import XCTest
@testable import AXTerm

@MainActor
final class NetRomNodesBroadcastPropertyTests: XCTestCase {

    private let origin = AX25Address(call: "K0EPI", ssid: 7)

    private func packet(_ payload: Data) -> Packet {
        Packet(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            from: origin,
            to: AX25Address(call: "NODES", ssid: 0),
            via: [],
            frameType: .ui,
            control: 0x03,
            pid: NetRomWire.pid,
            info: payload,
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil)
    }

    private func callsign(_ rng: inout PropertyRNG) -> AX25Address {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let digits = Array("0123456789")
        // Prefix, one digit, suffix: the shape real callsigns have.
        let prefix = String((0..<rng.int(in: 1...2)).map { _ in rng.pick(letters) })
        let suffix = String((0..<rng.int(in: 1...3)).map { _ in rng.pick(letters) })
        let call = String((prefix + String(rng.pick(digits)) + suffix).prefix(6))
        return AX25Address(call: call, ssid: rng.chance(0.4) ? 0 : rng.int(in: 1...15))
    }

    private func alias(_ rng: inout PropertyRNG) -> String {
        let pool = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<rng.int(in: 0...6)).map { _ in rng.pick(pool) })
    }

    func testAnyPayloadParsesWithoutTrapping() {
        checkProperty("nodes.parse.total", cases: 20_000) { rng, _ in
            var bytes = rng.bytes(rng.int(in: 0...260))
            if rng.chance(0.7), !bytes.isEmpty { bytes[0] = NetRomBroadcastParser.signatureByte }
            _ = NetRomBroadcastParser.parse(packet: packet(bytes))
        }
    }

    func testWhatTheEncoderSendsIsReadBackExactly() {
        checkProperty("nodes.roundtrip", cases: 5_000) { rng, violations in
            let entries = (0..<rng.int(in: 1...NetRomNodesBroadcast.maxEntriesPerFrame)).map { _ in
                NetRomNodesBroadcast.Entry(destination: callsign(&rng), alias: alias(&rng),
                                           bestNeighbor: callsign(&rng), quality: rng.byte())
            }
            let originAlias = alias(&rng)
            let payloads = NetRomNodesBroadcast.encode(originAlias: originAlias, entries: entries)
            violations.check(payloads.count == 1, "\(entries.count) entries made \(payloads.count) frames")
            guard let payload = payloads.first else { return }
            guard let result = NetRomBroadcastParser.parse(packet: packet(payload)) else {
                violations.record("the parser refused a broadcast AXTerm encoded (alias \"\(originAlias)\", \(entries.count) entries)")
                return
            }
            violations.check(result.entries.count == entries.count,
                             "\(entries.count) entries sent, \(result.entries.count) read (alias \"\(originAlias)\")")
            for (sent, read) in zip(entries, result.entries) {
                violations.check(read.destinationCallsign == sent.destination.display,
                                 "destination \(sent.destination.display) read as \(read.destinationCallsign)")
                violations.check(read.destinationAlias == sent.alias,
                                 "alias \"\(sent.alias)\" read as \"\(read.destinationAlias)\"")
                violations.check(read.bestNeighborCallsign == sent.bestNeighbor.display,
                                 "neighbor \(sent.bestNeighbor.display) read as \(read.bestNeighborCallsign)")
                violations.check(read.quality == Int(sent.quality), "quality \(sent.quality) read as \(read.quality)")
            }
        }
    }
}
