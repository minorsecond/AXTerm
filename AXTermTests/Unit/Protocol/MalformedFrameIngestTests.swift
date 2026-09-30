//
//  MalformedFrameIngestTests.swift
//  AXTermTests
//
//  A frame the decoder refuses must not become a packet or a heard station,
//  and must be logged with its reason (CLAUDE.md §4: malformed frames are
//  logged, not dropped silently).
//

import XCTest
@testable import AXTerm

@MainActor
final class MalformedFrameIngestTests: XCTestCase {

    private func makeEngine(_ logger: MockEventLogger) -> PacketEngine {
        let defaults = UserDefaults(suiteName: "AXTermTests-\(UUID().uuidString)") ?? .standard
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        return PacketEngine(
            maxPackets: 10, maxConsoleLines: 10, maxRawChunks: 10,
            settings: AppSettingsStore(defaults: defaults),
            packetStore: nil, consoleStore: nil, rawStore: nil,
            eventLogger: logger)
    }

    private func parserWarnings(_ logger: MockEventLogger) -> [[String: String]] {
        logger.entries
            .filter { $0.0 == .warning && $0.1 == .parser && $0.2 == "Failed to decode AX.25 frame" }
            .compactMap { $0.3 }
    }

    func testOvernightNoiseIsLoggedAndHeardByNobody() {
        let logger = MockEventLogger()
        let engine = makeEngine(logger)

        engine.handleIncomingData(KISS.encodeFrame(payload: AX25AddressValidationTests.overnightNoise))

        XCTAssertTrue(engine.packets.isEmpty)
        XCTAssertTrue(engine.stations.isEmpty)
        XCTAssertFalse(engine.stations.contains { $0.call.contains("V}") })
        let warnings = parserWarnings(logger)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?["reason"], "destination address: invalid character 0x3B at position 1")
        XCTAssertEqual(warnings.first?["byteCount"], "\(AX25AddressValidationTests.overnightNoise.count)")
    }

    func testRealFrameAfterTheNoiseIsStillHeard() throws {
        let logger = MockEventLogger()
        let engine = makeEngine(logger)
        // WA0DE-9 Mic-E off the air, 2026-09-29.
        let real = try XCTUnwrap(Data(hexString:
            "A672A4A6ACA260AE8260888A4072AE609C8A8840E0AE92888A6240E0AE92888A64406303F0"
            + "6070444D1C1E1D232F224A217D4152455344454320436F6D6D547261696C6572"))

        engine.handleIncomingData(KISS.encodeFrame(payload: AX25AddressValidationTests.overnightNoise))
        engine.handleIncomingData(KISS.encodeFrame(payload: real))

        XCTAssertEqual(engine.packets.count, 1)
        XCTAssertEqual(engine.packets.first?.from?.display, "WA0DE-9")
        XCTAssertEqual(engine.packets.first?.to?.display, "S9RSVQ")
        XCTAssertEqual(engine.stations.map(\.call), ["WA0DE-9"])
        XCTAssertEqual(parserWarnings(logger).count, 1)
    }

    func testBadDigipeaterIsLoggedRatherThanTruncated() {
        let logger = MockEventLogger()
        let engine = makeEngine(logger)
        var raw = Data()
        raw.append(AX25Address(call: "APRS").encodeForAX25(isLast: false))
        raw.append(AX25Address(call: "N0CALL", ssid: 9).encodeForAX25(isLast: false))
        raw.append(AX25Address(call: "WIDE1", ssid: 1).encodeForAX25(isLast: false))
        raw.append(Data([0xEE, 0x92, 0x88, 0x8A, 0x64, 0x40, 0x63]))  // "wIDE2-1": lower-case w
        raw.append(Data([0x03, 0xF0]) + Data(">hello".utf8))

        engine.handleIncomingData(KISS.encodeFrame(payload: raw))

        XCTAssertTrue(engine.packets.isEmpty)
        XCTAssertEqual(parserWarnings(logger).first?["reason"],
                       "digipeater 2 address: invalid character 0x77 at position 1")
    }
}
