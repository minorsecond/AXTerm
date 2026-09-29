import XCTest
@testable import AXTerm

/// The frames AXTerm actually transmits, proven on a real channel.
///
/// Everything else in this directory tests AXTerm's *answers*. This tests its
/// *transmissions* — the queries, the ping, the beacon — which is the half no
/// amount of reading or self-consistent round-tripping can establish, because
/// a frame that our own parser accepts may still be one nobody else does.
///
/// Every frame here is built by the production path: `APRSMessage` for the
/// information field, `AX25FrameBuilder.buildUI` with the tocall as the AX.25
/// destination exactly as `SessionCoordinator.sendAPRS` does, and
/// `OutboundFrame.encodeAX25()` for the bytes. The resulting hex is committed
/// The frames the rig transmits are built by `TestRig/scripts/axterm_onair.py`
/// with its *own* encoder and committed as `axterm-onair-frames.json`; this
/// suite asserts AXTerm's builders produce the same bytes, and
/// `AXTermOnAirResultTests` asserts the channel answered them correctly.
/// Neither half rests on the code under test. If the builders change, the hex
/// stops matching and the proof has to be re-earned on the air.
final class AXTermOnAirTests: XCTestCase {

    /// A frame built exactly the way `sendAPRS` builds one.
    private static let us = AX25Address(call: "ORACLE", ssid: 1)

    private func aprsFrame(info: String, via: [String] = []) -> Data {
        AX25FrameBuilder.buildUI(
            from: Self.us,
            to: AX25Address(call: APRSBeacon.tocall, ssid: 0),
            via: DigiPath.from(via),
            pid: 0xF0,
            payload: Data(info.utf8),
            displayInfo: info
        ).onRadio(RadioID(rawValue: "rig")).encodeAX25()
    }

    /// The catalogue of what we put on the air, in one place, so the fixture
    /// and the rig script cannot drift from it.
    struct OnAir {
        let name: String
        let info: String
        let via: [String]
    }

    /// The same fix, base-91 compressed (APRS 1.01 ch.9). AXTerm has always
    /// been able to transmit this and had never done so: base-91 is where a
    /// wrong divisor still yields a well-formed frame at the wrong place, so
    /// it is worth exactly nothing until another decoder says where it landed.
    static let compressedBeaconInfo = APRSBeacon.infoField(.init(
        latitude: 39.6117, longitude: -104.7317,
        symbolTable: "/", symbolCode: "-",
        comment: "AXTerm on-air proof", compressed: true))

    static let beaconInfo = APRSBeacon.infoField(.init(
        latitude: 39.6117, longitude: -104.7317,
        symbolTable: "/", symbolCode: "-",
        comment: "AXTerm on-air proof"))

    static var frames: [OnAir] {
        [
            .init(name: "ping-position",
                  info: APRSMessage.directedQueryInfo(to: "XASTIR-1", query: "?APRSP"),
                  via: []),
            .init(name: "query-version",
                  info: APRSMessage.directedQueryInfo(to: "XASTIR-1", query: "?VER"),
                  via: []),
            .init(name: "query-directs",
                  info: APRSMessage.directedQueryInfo(to: "XASTIR-1", query: "?APRSD"),
                  via: []),
            .init(name: "query-trace-digipeated",
                  info: APRSMessage.directedQueryInfo(to: "XASTIR-1", query: "?APRST"),
                  via: ["WIDE1-1"]),
            .init(name: "message-numbered",
                  info: APRSMessage.messageInfo(to: "XASTIR-1",
                                                text: "AXTerm on-air proof", number: "042"),
                  via: []),
            .init(name: "beacon-position", info: beaconInfo, via: []),
            .init(name: "beacon-compressed", info: compressedBeaconInfo, via: []),
            .init(name: "general-query", info: APRSMessage.generalQueryAllInfo, via: []),
        ]
    }

    // MARK: - The frames themselves

    /// Every APRS frame we transmit puts the tocall in the AX.25 destination
    /// and the recipient in the information field (ch.5). Asserted on the
    /// encoded bytes, not on the intent.
    func testEveryTransmittedFrameUsesTheTocallAsDestination() throws {
        for spec in Self.frames {
            let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: aprsFrame(info: spec.info,
                                                                        via: spec.via)),
                                        "\(spec.name) did not decode")
            XCTAssertEqual(decoded.to?.display, APRSBeacon.tocall, spec.name)
            XCTAssertEqual(decoded.from?.display, "ORACLE-1", spec.name)
            XCTAssertEqual(decoded.pid, 0xF0, "\(spec.name): APRS is always PID 0xF0")
            XCTAssertEqual(decoded.frameType, .ui, "\(spec.name): APRS is always UI")
        }
    }

    /// A digipeated frame carries the requested path unrepeated — we ask, the
    /// digipeater decides.
    func testARequestedPathIsTransmittedUnused() throws {
        let raw = aprsFrame(info: APRSMessage.directedQueryInfo(to: "XASTIR-1",
                                                               query: "?APRST"),
                            via: ["WIDE1-1"])
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: raw))
        XCTAssertEqual(decoded.via.map(\.display), ["WIDE1-1"])
        XCTAssertTrue(decoded.via.allSatisfy { !$0.repeated },
                      "we must not set the has-been-repeated bit ourselves")
    }

    /// Our beacon is a well-formed uncompressed position report that our own
    /// parser reads back at the coordinates we put in — necessary, not
    /// sufficient. `AXTermOnAirResultTests` is where a *different*
    /// implementation confirms it.
    func testOurBeaconIsAPositionReport() throws {
        XCTAssertTrue(Self.beaconInfo.hasPrefix("!"),
                      "expected a no-timestamp position report: \(Self.beaconInfo)")
        let parsed = try XCTUnwrap(
            APRSParser.parse(destination: APRSBeacon.tocall,
                             info: Data(Self.beaconInfo.utf8)),
            "our own parser could not read our own beacon")
        XCTAssertEqual(parsed.latitude, 39.6117, accuracy: 0.001)
        XCTAssertEqual(parsed.longitude, -104.7317, accuracy: 0.001)
    }

    /// The bytes are pinned against what was actually transmitted and proven.
    func testTheTransmittedBytesAreTheOnesProvenOnTheAir() throws {
        let url = try XCTUnwrap(
            Bundle(for: AXTermOnAirTests.self)
                .url(forResource: "axterm-onair-frames", withExtension: "json"),
            "axterm-onair-frames.json is not in the test bundle")
        let fixture = try JSONDecoder().decode([String: String].self,
                                               from: Data(contentsOf: url))
        for spec in Self.frames {
            let hex = aprsFrame(info: spec.info, via: spec.via)
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hex, fixture[spec.name],
                           "\(spec.name) is no longer the frame that was proven; "
                           + "re-run TestRig/scripts/axterm_onair.py")
        }
    }
}
