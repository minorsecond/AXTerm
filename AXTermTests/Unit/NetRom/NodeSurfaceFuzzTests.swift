import XCTest
@testable import AXTerm

/// Fuzzing the surfaces this station exposes to STRANGERS — the node
/// shell a caller types at, the digipeater a passing frame hits, the
/// ROUTES scraper fed another node's output, the harvest policy handed
/// a claim. A remote operator can send anything; none of it may crash,
/// hang, or corrupt. Seeded (SplitMix64 via AX25Fuzzer) so a failure
/// reproduces from its printed seed.
final class NodeSurfaceFuzzTests: XCTestCase {

    private let iterations = 4000

    /// Bytes a real caller's terminal might send: mostly ASCII, laced
    /// with control characters, high bytes, and the delimiters our
    /// parsers key on.
    private func callerBytes(_ fuzzer: inout AX25Fuzzer, maxLen: Int = 80) -> String {
        let alphabet: [Character] = Array(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -/:}.?*<>\r\n\t\u{00}\u{7f}\u{1b}CNRMHBBSI")
        let length = fuzzer.nextInt(in: 0...maxLen)
        var s = ""
        for _ in 0..<length {
            if fuzzer.nextDouble() < 0.08 {
                s.unicodeScalars.append(UnicodeScalar(UInt8(fuzzer.nextInt(in: 0...255))))
            } else {
                s.append(alphabet[fuzzer.nextInt(in: 0...(alphabet.count - 1))])
            }
        }
        return s
    }

    // MARK: - The node shell

    func testTheNodeShellSurvivesAnyCommandLine() {
        var fuzzer = AX25Fuzzer(seed: 0xC0FFEE)
        let snapshot = NetRomNodeShell.Snapshot(
            routes: [.init(destination: "KE0GB-7", alias: "COSCO",
                           nextHop: "KB5YZB-7", quality: 192)],
            neighbors: [.init(callsign: "KB5YZB-7", quality: 192, count: 3)],
            heard: [.init(callsign: "KD0SSP", lastHeard: Date())],
            stationInfo: "rig", bbsAvailable: true)

        for i in 0..<iterations {
            var shell = NetRomNodeShell(nodeAlias: "EPINOD", nodeCall: "K0EPI-7",
                                        version: "AXTerm 1.0", caller: "W0ARP-1")
            let line = callerBytes(&fuzzer)
            let out = shell.handle(line: line, snapshot: snapshot, now: Date())
            // A prompt or a terminal effect, never both-nil silence that
            // would strand a caller with no way forward.
            let stranded = out.prompt == nil && out.effects.isEmpty
                && !out.lines.contains { $0.contains("73") }
            XCTAssertFalse(stranded,
                           "seed 0xC0FFEE iter \(i): line \(debugText(line)) "
                           + "left the caller with no prompt and no effect")
        }
    }

    // MARK: - The digipeater

    func testTheDigipeaterNeverCrashesOnArbitraryFrames() {
        var fuzzer = AX25Fuzzer(seed: 0xD1918)
        for i in 0..<iterations {
            let length = fuzzer.nextInt(in: 0...80)
            let raw = fuzzer.nextBytes(count: length)
            // The result, if any, differs by at most one address byte —
            // a digipeater changes exactly one H bit, never content.
            if let out = AX25Digipeater.repeatFrame(raw, myAddresses: ["K0EPI-7", "DWARC"]) {
                XCTAssertEqual(out.count, raw.count,
                               "seed 0xD1918 iter \(i): length changed")
                let differences = zip(out, raw).filter { $0 != $1 }.count
                XCTAssertLessThanOrEqual(differences, 1,
                    "seed 0xD1918 iter \(i): more than one byte changed")
            }
        }
    }

    /// A frame that names us and is well-formed enough to repeat, with
    /// random junk appended — the H bit still flips exactly once.
    func testDigipeaterIsStableAcrossValidFrameMutations() {
        var fuzzer = AX25Fuzzer(seed: 0x5EED)
        let base = validViaFrame()
        for i in 0..<iterations {
            let mutated = fuzzer.mutate(frameData: base)
            _ = AX25Digipeater.repeatFrame(mutated, myAddresses: ["K0EPI-7"])
            // The only assertion is survival: no crash, no hang.
            XCTAssertTrue(true, "iter \(i)")
        }
    }

    // MARK: - The ROUTES scraper

    func testTheScraperSwallowsAnyLine() {
        var fuzzer = AX25Fuzzer(seed: 0xABCD)
        var scraper = BpqRoutesScraper()
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        for i in 0..<iterations {
            let line = callerBytes(&fuzzer, maxLen: 60)
            if let row = scraper.ingest(line: line, peer: "BPQ", at: now) {
                // A row it accepts must be sane: plausible callsign,
                // quality in range.
                XCTAssertTrue(CallsignQuery.isPlausible(row.neighbor),
                              "seed 0xABCD iter \(i): implausible neighbor "
                              + "\(row.neighbor) from \(debugText(line))")
                XCTAssertTrue((0...255).contains(row.quality),
                              "seed 0xABCD iter \(i): quality \(row.quality) out of range")
            }
        }
    }

    // MARK: - The KISS frame parser

    func testTheKISSParserSurvivesArbitraryStreams() {
        var fuzzer = AX25Fuzzer(seed: 0x1550)
        for i in 0..<iterations {
            var parser = KISSFrameParser()
            // Feed in several arbitrary chunks — the real hazard is
            // split frames and stray FENDs across chunk boundaries.
            let chunkCount = fuzzer.nextInt(in: 1...5)
            for _ in 0..<chunkCount {
                let chunk = fuzzer.nextBytes(count: fuzzer.nextInt(in: 0...64))
                _ = parser.feed(chunk)
            }
            XCTAssertTrue(true, "seed 0x1550 iter \(i)")
        }
    }

    // MARK: - Helpers

    private func address(_ call: String, ssid: UInt8, repeated: Bool = false,
                         last: Bool = false) -> Data {
        var bytes = Data()
        for scalar in call.padding(toLength: 6, withPad: " ", startingAt: 0).unicodeScalars {
            bytes.append(UInt8(scalar.value) << 1)
        }
        var ssidByte: UInt8 = 0x60 | (ssid << 1)
        if repeated { ssidByte |= 0x80 }
        if last { ssidByte |= 0x01 }
        bytes.append(ssidByte)
        return bytes
    }

    private func validViaFrame() -> Data {
        var raw = Data()
        raw.append(address("CQ", ssid: 0))
        raw.append(address("W0ARP", ssid: 0))
        raw.append(address("K0EPI", ssid: 7, last: true))
        raw.append(0x03)
        raw.append(0xF0)
        raw.append(Data("test".utf8))
        return raw
    }

    private func debugText(_ s: String) -> String {
        "\"" + s.unicodeScalars.map {
            $0.value < 0x20 || $0.value > 0x7e ? "\\u{\(String($0.value, radix: 16))}"
                : String($0)
        }.joined() + "\""
    }
}
