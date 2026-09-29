import XCTest
@testable import AXTerm

/// What the channel did with AXTerm's own transmissions.
///
/// `AXTermOnAirTests` proves AXTerm emits exactly the bytes in
/// `axterm-onair-frames.json`. This proves those bytes are correct: each was
/// modulated onto a shared 1200-baud AFSK channel by its own modem, and a real
/// Xastir 2.1.8 — plus, for the beacon, Direwolf's independent parser —
/// responded the way the specification says it should.
///
/// Together the two suites close the loop that reading a document cannot:
/// AXTerm's queries, its ping, its message and its beacon are not merely
/// self-consistent, they are understood by other implementations on the air.
final class AXTermOnAirResultTests: XCTestCase {

    struct OnAir: Decodable {
        struct Reply: Decodable {
            let afterS: Double
            let src: String
            let infoAscii: String
            enum CodingKeys: String, CodingKey {
                case src, afterS = "after_s", infoAscii = "info_ascii"
            }
        }
        struct Frame: Decodable {
            let info: String
            let via: [String]
            let frameHex: String
            let replies: [Reply]
            let decodedByDirewolf: [String]?
            enum CodingKeys: String, CodingKey {
                case info, via, replies
                case frameHex = "frame_hex"
                case decodedByDirewolf = "decoded_by_direwolf"
            }
        }
        let askedAs: String
        let frames: [String: Frame]
        enum CodingKeys: String, CodingKey {
            case frames, askedAs = "asked_as"
        }
    }

    private func onAir() throws -> OnAir {
        let url = try XCTUnwrap(
            Bundle(for: AXTermOnAirResultTests.self)
                .url(forResource: "axterm-onair", withExtension: "json"),
            "axterm-onair.json is not in the test bundle")
        return try JSONDecoder().decode(OnAir.self, from: Data(contentsOf: url))
    }

    private func frame(_ name: String, in capture: OnAir) throws -> OnAir.Frame {
        try XCTUnwrap(capture.frames[name], "no on-air record for \(name)")
    }

    private func body(_ reply: OnAir.Reply) -> String {
        let text = reply.infoAscii
        guard text.hasPrefix(":"), text.count > 11 else { return text }
        return String(text.dropFirst(11))
    }

    // MARK: - The ping

    /// The map's Ping — a directed `?APRSP` — draws a position report, and one
    /// that names nobody. This is the measured basis for the whole
    /// `APRSAnswerEvidence` machinery: the answer is indistinguishable from an
    /// ordinary beacon because it *is* one.
    func testOurPingDrawsAnUnaddressedPositionReport() throws {
        let reply = try XCTUnwrap(try frame("ping-position", in: try onAir()).replies.first,
                                  "our ?APRSP was not answered")
        XCTAssertFalse(reply.infoAscii.hasPrefix(":"),
                       "a position answer addresses nobody: \(reply.infoAscii)")
        XCTAssertTrue(reply.infoAscii.hasPrefix("="),
                      "expected a position report, got \(reply.infoAscii)")
    }

    // MARK: - The queries

    /// `?VER` comes back as a message addressed to us — the provable class the
    /// Ask sheet promises.
    func testOurVersionQueryDrawsAMessageAddressedToUs() throws {
        let cap = try onAir()
        let reply = try XCTUnwrap(try frame("query-version", in: cap).replies.first)
        XCTAssertTrue(reply.infoAscii.hasPrefix(":\(cap.askedAs.padding(toLength: 9, withPad: " ", startingAt: 0)):"),
                      "expected a message to us, got \(reply.infoAscii)")
        XCTAssertTrue(body(reply).lowercased().contains("xastir"), body(reply))
    }

    func testOurDirectsQueryDrawsTheDirectsList() throws {
        let cap = try onAir()
        let reply = try XCTUnwrap(try frame("query-directs", in: cap).replies.first)
        XCTAssertTrue(body(reply).hasPrefix("Directs= "), body(reply))
        XCTAssertTrue(body(reply).contains(cap.askedAs),
                      "we had just transmitted, so we belong in the list")
    }

    /// The one that matters most for the trace: our query went out asking for
    /// `WIDE1-1`, a real digipeater repeated it, and Xastir answered *both*
    /// copies — quoting the requested path unmarked on one and the digipeater
    /// with its has-been-repeated star on the other. That pair is the whole
    /// specification of the field in one exchange, and it is what
    /// `APRSMessagingService.traceAnswer` now reproduces.
    func testOurTraceQueryDrawsBothTheRequestedAndTheRepeatedPath() throws {
        let bodies = Set(try frame("query-trace-digipeated", in: try onAir())
            .replies.map(body))
        XCTAssertTrue(bodies.contains("PATH= ORACLE-1>APZAXT,WIDE1-1"),
                      "the un-digipeated copy: \(bodies)")
        XCTAssertTrue(bodies.contains("PATH= ORACLE-1>APZAXT,RFDIGI-1*"),
                      "the digipeated copy, star and all: \(bodies)")
    }

    /// And AXTerm produces the same two answers from the same two frames.
    func testAXTermWouldAnswerThoseTwoFramesIdentically() throws {
        let cap = try onAir()
        for (via, expected) in [(["WIDE1-1"], "PATH= ORACLE-1>APZAXT,WIDE1-1"),
                                (["RFDIGI-1*"], "PATH= ORACLE-1>APZAXT,RFDIGI-1*")] {
            let ctx = APRSMessagingService.InboundContext(
                sender: cap.askedAs, ourCalls: ["XASTIR-1"], radioID: "rig",
                replyPath: [], viaDirect: false, receivedAt: Date(),
                destination: "APZAXT", viaPath: via)
            XCTAssertEqual(APRSMessagingService.traceAnswerForTesting(ctx), expected)
        }
    }

    // MARK: - The message

    /// Our numbered message is acknowledged, which is the reference decoder
    /// confirming it found our nine-character padded addressee and our message
    /// number exactly where APRS 1.01 ch.14 puts them.
    func testOurNumberedMessageIsAcknowledged() throws {
        let cap = try onAir()
        let replies = try frame("message-numbered", in: cap).replies.map(\.infoAscii)
        XCTAssertTrue(replies.contains(APRSMessage.ackInfo(to: cap.askedAs, number: "042")),
                      "expected our own ack encoding back, got \(replies)")
    }

    // MARK: - The beacon

    /// A beacon solicits no reply, and got none — which on its own proves
    /// nothing. The proof is that a third implementation, Direwolf's parser,
    /// read the position, the symbol and the comment straight off the air.
    func testOurBeaconIsDecodedByAnotherImplementation() throws {
        let beacon = try frame("beacon-position", in: try onAir())
        XCTAssertTrue(beacon.replies.isEmpty, "a beacon asks for nothing")

        let decode = try XCTUnwrap(beacon.decodedByDirewolf,
                                   "no independent decode was recorded")
        let text = decode.joined(separator: "\n")
        XCTAssertTrue(text.contains("Position"), text)
        XCTAssertTrue(text.contains("N 39 36.7000"), "latitude: \(text)")
        XCTAssertTrue(text.contains("W 104 43.9000"), "longitude: \(text)")
        XCTAssertTrue(text.contains("House"), "symbol /- is a house: \(text)")
        XCTAssertTrue(text.contains("AXTerm on-air proof"), "comment: \(text)")
    }

    /// The compressed beacon, which is the one that needed this most. AXTerm
    /// encoded 39.6117 / −104.7317 into base-91; Direwolf, which has never
    /// seen AXTerm's encoder, read `N 39 36.7019, W 104 43.9021` off the air —
    /// 39.61170 / −104.73170, the same place to a ten-thousandth of a minute.
    /// A self-consistent round trip through our own decoder could not have
    /// told a correct divisor from a wrong one; this can.
    func testOurCompressedBeaconLandsWhereWeEncodedIt() throws {
        let beacon = try frame("beacon-compressed", in: try onAir())
        let decode = try XCTUnwrap(beacon.decodedByDirewolf,
                                   "no independent decode was recorded")
        let text = decode.joined(separator: "\n")
        XCTAssertTrue(text.contains("Position"), text)
        XCTAssertTrue(text.contains("N 39 36.7019"), "latitude: \(text)")
        XCTAssertTrue(text.contains("W 104 43.9021"), "longitude: \(text)")
        XCTAssertTrue(text.contains("House"), "symbol /- survives compression: \(text)")
        XCTAssertTrue(text.contains("AXTerm on-air proof"), "comment: \(text)")

        // And that reading is the position we asked for.
        XCTAssertEqual(39 + 36.7019 / 60, 39.6117, accuracy: 0.00002)
        XCTAssertEqual(-(104 + 43.9021 / 60), -104.7317, accuracy: 0.00002)
    }

    /// Both beacons carry the same fix, so the two encodings must agree with
    /// each other on the air as well as with the source. They do — to within
    /// the uncompressed format's own hundredth-of-a-minute resolution, which
    /// is the only difference there should be.
    func testTheTwoBeaconEncodingsAgreeOnTheAir() throws {
        let cap = try onAir()
        func heard(_ name: String) throws -> (lat: Double, lon: Double) {
            let text = try XCTUnwrap(try frame(name, in: cap).decodedByDirewolf)
                .joined(separator: " ")
            let re = try NSRegularExpression(
                pattern: #"N (\d+) ([\d.]+), W (\d+) ([\d.]+)"#)
            let m = try XCTUnwrap(
                re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                "no position in \(text)")
            func group(_ i: Int) throws -> Double {
                let r = try XCTUnwrap(Range(m.range(at: i), in: text))
                return try XCTUnwrap(Double(text[r]))
            }
            return (try group(1) + group(2) / 60, -(try group(3) + group(4) / 60))
        }
        let plain = try heard("beacon-position")
        let packed = try heard("beacon-compressed")
        XCTAssertEqual(plain.lat, packed.lat, accuracy: 0.0002)
        XCTAssertEqual(plain.lon, packed.lon, accuracy: 0.0002)
    }

    /// Direwolf classified each transmission by type without being told: the
    /// directed queries as directed queries, `?APRS?` as a general one, and the
    /// message as a message *addressed to XASTIR-1 and numbered 042*. That
    /// last one is APRS 1.01 ch.14 read back to us field by field — the nine
    /// character padded addressee and the `{` number both found where the
    /// specification puts them, by a parser that has never seen our encoder.
    func testAnotherImplementationClassifiesEachTransmissionCorrectly() throws {
        let cap = try onAir()
        let expected = [
            "ping-position": "Directed Station Query",
            "query-version": "Directed Station Query",
            "query-directs": "Directed Station Query",
            "query-trace-digipeated": "Directed Station Query",
            "general-query": "General Query",
            "beacon-position": "Position",
            "beacon-compressed": "Position",
        ]
        for (name, kind) in expected {
            let decode = try XCTUnwrap(try frame(name, in: cap).decodedByDirewolf,
                                       "\(name): no independent decode")
            XCTAssertTrue(decode.joined(separator: " ").contains(kind),
                          "\(name) should read as \(kind): \(decode)")
        }
        let message = try XCTUnwrap(try frame("message-numbered", in: cap).decodedByDirewolf)
            .joined(separator: " ")
        XCTAssertTrue(message.contains(#"APRS Message 042 for "XASTIR-1""#), message)
    }

    /// Direwolf reads our tocall as experimental — `AP` + `Z` + `AXT`, the
    /// unregistered range. Worth pinning: it is the same reading aprs.fi gives
    /// and the reason our frames show as "Unknown: Experimental" there.
    func testOurTocallIsReadAsExperimentalByAnotherImplementation() throws {
        let decode = try XCTUnwrap(
            try frame("beacon-position", in: try onAir()).decodedByDirewolf)
        XCTAssertTrue(decode.joined().contains("Experimental"),
                      "APZAXT should read as experimental: \(decode)")
        XCTAssertTrue(APRSBeacon.tocall.hasPrefix("APZ"))
    }

    // MARK: - The general query

    /// The broadcast query, and the timing rule that goes with it. Every
    /// station in earshot receives the same frame at the same instant, so
    /// Bruninga's rule spreads the answers over a random 0-120 s rather than
    /// letting them collide. Measured here at the far end of that spread —
    /// which is exactly why `APRSMessagingService.generalQueryWindow` is 120 s
    /// and why the answer is scheduled rather than sent at once.
    func testOurGeneralQueryIsAnsweredAfterTheRandomSpread() throws {
        let general = try frame("general-query", in: try onAir())
        XCTAssertEqual(general.info, APRSMessage.generalQueryAllInfo)
        let reply = try XCTUnwrap(general.replies.first, "?APRS? went unanswered")
        XCTAssertGreaterThan(reply.afterS, 5,
                             "answered too promptly for a general query: it must be spread")
        XCTAssertLessThanOrEqual(reply.afterS,
                                 APRSMessagingService.generalQueryWindow + 15,
                                 "outside Bruninga's spread")
        XCTAssertFalse(reply.infoAscii.hasPrefix(":"),
                       "a general query is answered with a broadcast, not a message")
    }

    /// Directed queries are answered at once; the general query is not. The
    /// contrast is the rule, so it is asserted as a contrast.
    func testDirectedQueriesAreImmediateAndTheGeneralQueryIsNot() throws {
        let cap = try onAir()
        let general = try XCTUnwrap(try frame("general-query", in: cap).replies.first).afterS
        for name in ["ping-position", "query-version", "query-directs"] {
            let directed = try XCTUnwrap(try frame(name, in: cap).replies.first).afterS
            XCTAssertLessThan(directed, 10, "\(name) should be answered on receipt")
            XCTAssertLessThan(directed, general,
                              "\(name) must be faster than a spread general query")
        }
    }
}
