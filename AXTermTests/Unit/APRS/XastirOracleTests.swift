import XCTest
import GRDB
@testable import AXTerm

/// AXTerm's query answers, checked against what a real Xastir actually says.
///
/// Until now "matches Xastir" was a prose comment: I read `src/db.c` and wrote
/// down what I thought it did. Nothing failed when the reading was wrong — and
/// it was wrong. `?APRST` is answered `PATH= sender>DESTINATION,digis`, quoting
/// the whole received path; reading the format string `"PATH= %s>%s"` in
/// isolation, I built `sender>digis` and dropped the destination. This suite is
/// what catches that class of mistake.
///
/// The fixture is byte-exact capture from Xastir 2.1.8 on the test rig
/// (`TestRig/scripts/xastir_oracle.py`, `docker compose --profile aprs up -d`),
/// asked over a simulated radio channel. It is checked in so the assertions run
/// in CI without Docker; regenerate it when the reference version changes.
final class XastirOracleTests: XCTestCase {

    struct Oracle: Decodable {
        struct Reply: Decodable {
            let src: String
            let infoAscii: String
            let addressedToUs: Bool
            let afterS: Double
            enum CodingKeys: String, CodingKey {
                case src
                case infoAscii = "info_ascii"
                case addressedToUs = "addressed_to_us"
                case afterS = "after_s"
            }
        }
        struct Exchange: Decodable {
            let query: String
            let sentVia: [String]
            let replies: [Reply]
            enum CodingKeys: String, CodingKey {
                case query, replies
                case sentVia = "sent_via"
            }
        }
        let target: String
        let askedAs: String
        let exchanges: [Exchange]
        enum CodingKeys: String, CodingKey {
            case target, exchanges
            case askedAs = "asked_as"
        }
    }

    private static func loadOracle() throws -> Oracle {
        let url = try XCTUnwrap(
            Bundle(for: XastirOracleTests.self)
                .url(forResource: "xastir-oracle", withExtension: "json"),
            "xastir-oracle.json is not in the test bundle")
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    private func exchange(_ query: String, via: [String] = [],
                          in oracle: Oracle) throws -> Oracle.Exchange {
        try XCTUnwrap(oracle.exchanges.first { $0.query == query && $0.sentVia == via },
                      "no captured exchange for \(query) via \(via)")
    }

    /// The reply text a station sends back, with the APRS message envelope
    /// (`:ADDRESSEE:`) stripped — the part our own code generates.
    private func answerText(_ reply: Oracle.Reply) -> String {
        let body = reply.infoAscii.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix(":"), body.count > 10 else { return body }
        return String(body.dropFirst(11))
    }

    // MARK: - The evidence classes, measured rather than assumed

    /// The distinction the whole Ask sheet is built on, taken from the wire:
    /// four of Xastir's answers are messages addressed to the asker, and the
    /// position answer is a broadcast that names nobody.
    func testWhichQueriesXastirAnswersWithAMessage() throws {
        let oracle = try Self.loadOracle()
        for (query, provable) in [("?VER", true), ("?APRSD", true),
                                  ("?APRST", true), ("?PING?", true),
                                  ("?APRSP", false)] {
            let ex = try exchange(query, in: oracle)
            let reply = try XCTUnwrap(ex.replies.first, "\(query) went unanswered")
            XCTAssertEqual(reply.addressedToUs, provable,
                           "\(query): Xastir answered \(reply.infoAscii)")
            if let kind = APRSDirectedQuery(rawValue: query) {
                XCTAssertEqual(kind.isProvable, provable,
                               "\(query): our catalogue disagrees with Xastir")
            }
        }
    }

    /// `?APRSP` is answered with an ordinary position report carrying no
    /// reference to the query — the fact `APRSAnswerEvidence` exists for. If
    /// this ever starts coming back addressed, the inference machinery is
    /// unnecessary and should go.
    func testThePositionAnswerIsAnAnonymousBroadcast() throws {
        let oracle = try Self.loadOracle()
        let reply = try XCTUnwrap(try exchange("?APRSP", in: oracle).replies.first)
        XCTAssertFalse(reply.addressedToUs)
        XCTAssertTrue(reply.infoAscii.hasPrefix("="),
                      "expected a position report, got \(reply.infoAscii)")
        XCTAssertFalse(reply.infoAscii.contains(oracle.askedAs),
                       "nothing in the answer identifies who asked")
    }

    /// A directed query is answered on receipt — Xastir sets `transmit_now`.
    /// This is why `APRSPingTracker.window` is 120 s of slack rather than a
    /// tuned figure, and why a silent ping means something.
    func testDirectedQueriesAreAnsweredImmediately() throws {
        let oracle = try Self.loadOracle()
        for query in ["?APRSP", "?VER", "?APRSD", "?APRST"] {
            let reply = try XCTUnwrap(try exchange(query, in: oracle).replies.first)
            XCTAssertLessThan(reply.afterS, 5.0,
                              "\(query) took \(reply.afterS)s — not the immediate answer")
        }
    }

    // MARK: - Our answers against theirs

    /// The bug this suite was built to catch. Xastir quotes the entire received
    /// path back, destination included; ours dropped the destination.
    func testXastirsTraceAnswerQuotesTheWholeReceivedPath() throws {
        let oracle = try Self.loadOracle()
        let direct = try XCTUnwrap(try exchange("?APRST", in: oracle).replies.first)
        XCTAssertEqual(answerText(direct), "PATH= ORACLE-1>APZAXT")

        let viaPath = try exchange("?APRST", via: ["RELAY", "WIDE2-1"], in: oracle)
        let digipeated = try XCTUnwrap(viaPath.replies.first)
        XCTAssertEqual(answerText(digipeated), "PATH= ORACLE-2>APZAXT,RELAY,WIDE2-1")
    }

    /// `?PING?` is `?APRST` under another name, byte for byte.
    func testPingIsTheSameAnswerAsTrace() throws {
        let oracle = try Self.loadOracle()
        let trace = try XCTUnwrap(try exchange("?APRST", in: oracle).replies.first)
        let ping = try XCTUnwrap(try exchange("?PING?", in: oracle).replies.first)
        XCTAssertEqual(answerText(trace), answerText(ping))
    }

    /// Xastir's directs list is `Directs=` followed by space-separated
    /// callsigns — the shape `APRSMessagingService` emits.
    func testOurDirectsAnswerMatchesXastirsFormat() throws {
        let oracle = try Self.loadOracle()
        let reply = try XCTUnwrap(try exchange("?APRSD", in: oracle).replies.first)
        XCTAssertTrue(answerText(reply).hasPrefix("Directs="),
                      "got \(answerText(reply))")
        XCTAssertTrue(answerText(reply).contains(oracle.askedAs),
                      "we had just transmitted, so we should be in its direct list")
    }

    // MARK: - What Xastir declines to answer

    /// The queries the Ask sheet offers that the reference implementation does
    /// not answer. Xastir accepts them as well-formed and returns nothing —
    /// `?APRSS`, `?APRSO`, `?APRSM` and `?APRSH` are all marked "NOT
    /// IMPLEMENTED YET" in `db.c`, and `?WX?`/`?IGATE?` do not apply to it.
    /// Silence here is the expected behaviour, not a rig failure.
    func testTheQueriesXastirDoesNotImplement() throws {
        let oracle = try Self.loadOracle()
        for query in ["?APRSS", "?APRSO", "?APRSM", "?APRSH", "?IGATE?", "?WX?"] {
            let ex = try exchange(query, in: oracle)
            XCTAssertTrue(ex.replies.isEmpty,
                          "\(query) was answered: \(ex.replies.map { $0.infoAscii })")
        }
    }

    /// Case is part of the protocol. The spec writes query tokens in upper
    /// case and Xastir refuses anything else outright rather than guessing —
    /// the rule `APRSMessagingService` and `APRSStationQuery.normalize` follow.
    func testALowercaseQueryIsRefused() throws {
        let oracle = try Self.loadOracle()
        XCTAssertTrue(try exchange("?aprsp", in: oracle).replies.isEmpty,
                      "Xastir answered a lowercase query")
        XCTAssertFalse(try exchange("?APRSP", in: oracle).replies.isEmpty,
                       "...but the uppercase one must still work, or the "
                       + "capture proves nothing")
    }

    /// Every station on the channel used its real tocall, and Xastir's is
    /// APX218 — the destination is software identity, never the addressee.
    func testXastirAddressesRepliesInThePayloadNotTheAX25Destination() throws {
        let oracle = try Self.loadOracle()
        for ex in oracle.exchanges {
            for reply in ex.replies {
                XCTAssertEqual(reply.src, oracle.target)
                XCTAssertTrue(reply.infoAscii.hasPrefix(":") == reply.addressedToUs,
                              "addressing lives in the info field: \(reply.infoAscii)")
            }
        }
    }
}

/// The differential test: put AXTerm in Xastir's shoes and compare the bytes.
///
/// `XastirOracleTests` asserts what the reference implementation says.
/// This asserts that *we* say the same thing when asked the same question over
/// the same path — which is the claim "AXTerm matches Xastir" actually makes,
/// and the one that was never checked.
@MainActor
final class XastirDifferentialTests: XCTestCase {

    private var sent: [APRSOutbound] = []

    /// A service standing in for the rig's XASTIR-1, so the answers are
    /// directly comparable to the captured ones.
    private func standIn() throws -> APRSMessagingService {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let svc = APRSMessagingService(store: SQLiteAPRSMessageStore(dbQueue: queue))
        svc.autoReply = .full
        svc.send = { self.sent.append($0) }
        svc.positionInfo = { "=3936.70N/10443.90W-AXTerm rig oracle" }
        svc.versionInfo = { "xastir 2.1.8" }
        // Exactly what the rig's Xastir had heard when the fixture was
        // captured, so the two lists are directly comparable.
        svc.heardDirect = { ["ORACLE-1", "ORACLE-2"] }
        return svc
    }

    /// Exactly the frame the capture script transmitted.
    private func asAsked(_ sender: String, via: [String] = [])
        -> APRSMessagingService.InboundContext {
        .init(sender: sender, ourCalls: ["XASTIR-1"], radioID: "rig",
              replyPath: via.reversed(), viaDirect: via.isEmpty,
              receivedAt: Date(), destination: "APZAXT", viaPath: via)
    }

    /// The text we would put in the message body for a query.
    private func answer(to query: String, from sender: String = "ORACLE-1",
                        via: [String] = []) throws -> String? {
        sent = []
        let svc = try standIn()
        svc.receive(.directedQuery(addressee: "XASTIR-1", query: query),
                    context: asAsked(sender, via: via))
        guard let info = sent.first?.info else { return nil }
        guard info.hasPrefix(":"), info.count > 11 else { return info }
        return String(info.dropFirst(11))
    }

    private func xastirsAnswer(_ query: String, via: [String] = []) throws -> String? {
        let url = try XCTUnwrap(Bundle(for: XastirOracleTests.self)
            .url(forResource: "xastir-oracle", withExtension: "json"))
        let oracle = try JSONDecoder().decode(
            XastirOracleTests.Oracle.self, from: Data(contentsOf: url))
        let ex = try XCTUnwrap(oracle.exchanges.first {
            $0.query == query && $0.sentVia == via
        })
        guard let reply = ex.replies.first else { return nil }
        let body = reply.infoAscii.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix(":"), body.count > 10 else { return body }
        return String(body.dropFirst(11))
    }

    /// Byte-for-byte on the trace, direct and digipeated. This is the assertion
    /// that would have failed before the fix.
    func testOurTraceAnswerIsIdenticalToXastirs() async throws {
        XCTAssertEqual(try answer(to: "?APRST"), try xastirsAnswer("?APRST"))
        XCTAssertEqual(try answer(to: "?APRST", from: "ORACLE-2",
                                  via: ["RELAY", "WIDE2-1"]),
                       try xastirsAnswer("?APRST", via: ["RELAY", "WIDE2-1"]))
    }

    /// `?PING?` and `?APRST` are the same query; we must not diverge on the
    /// alias either.
    func testOurPingAnswerIsIdenticalToXastirs() async throws {
        XCTAssertEqual(try answer(to: "?PING?"), try xastirsAnswer("?PING?"))
    }

    /// The `Directs=` shape, with our own heard list standing in for Xastir's.
    func testOurDirectsAnswerHasXastirsShape() async throws {
        let ours = try XCTUnwrap(try answer(to: "?APRSD"))
        let theirs = try XCTUnwrap(try xastirsAnswer("?APRSD"))
        XCTAssertEqual(ours, theirs,
                       "Xastir puts a space before every callsign, including the first")
    }

    /// A position query is answered with the position itself — a broadcast, no
    /// addressee — in both implementations.
    func testOurPositionAnswerIsABroadcastLikeXastirs() async throws {
        sent = []
        let svc = try standIn()
        svc.receive(.directedQuery(addressee: "XASTIR-1", query: "?APRSP"),
                    context: asAsked("ORACLE-1"))
        let info = try XCTUnwrap(sent.first?.info)
        XCTAssertFalse(info.hasPrefix(":"), "a posit names nobody")
        XCTAssertEqual(info, try xastirsAnswer("?APRSP"))
    }

    /// The gap this whole exercise exposed: the Ask sheet offers more queries
    /// than we answer, and the ones we do not answer must produce *no
    /// transmission* — not a wrong answer, not a position — exactly as Xastir
    /// produces none.
    ///
    /// `?APRSO` used to be on this list and is deliberately not any more; see
    /// `testWeAnswerTheObjectQueryThatXastirDoesNot`.
    func testTheQueriesWeDoNotImplementTransmitNothing() async throws {
        for query in ["?APRSS", "?APRSM", "?APRSH K0EPI", "?IGATE?", "?WX?"] {
            sent = []
            let svc = try standIn()
            svc.receive(.directedQuery(addressee: "XASTIR-1", query: query),
                        context: asAsked("ORACLE-1"))
            XCTAssertTrue(sent.isEmpty,
                          "\(query) put \(sent.map(\.info)) on the air; Xastir answers nothing")
        }
    }

    /// One deliberate divergence, recorded here so it stays deliberate.
    ///
    /// Xastir recognises `?APRSO` as a legal query and answers nothing —
    /// `db.c` marks it `// NOT IMPLEMENTED YET`. We answer it, because it is
    /// APRS 1.01 ch.15 and because placing objects made it a real question:
    /// a station asking what objects we hold should not get the same silence
    /// as from a station that never heard of the query.
    ///
    /// This test exists because the differential suite failed when `?APRSO`
    /// started answering, which is exactly what it is for. Differing from
    /// Xastir is allowed; differing by accident is not.
    func testWeAnswerTheObjectQueryThatXastirDoesNot() async throws {
        sent = []
        let svc = try standIn()
        svc.ownObjects = { [] }
        svc.receive(.directedQuery(addressee: "XASTIR-1", query: "?APRSO"),
                    context: asAsked("ORACLE-1"))
        XCTAssertEqual(sent.count, 1, "silence is what Xastir sends; we say something")
        XCTAssertEqual(sent.first?.info,
                       APRSMessage.messageInfo(to: "ORACLE-1", text: "No objects", number: nil))
    }

    /// Case, again — but as a transmission test rather than a catalogue one.
    /// Xastir treats a lowercase query as illegal and stays silent.
    func testALowercaseQueryTransmitsNothing() async throws {
        for query in ["?aprsp", "?ver", "?aprst", "?aprsd"] {
            sent = []
            let svc = try standIn()
            svc.receive(.directedQuery(addressee: "XASTIR-1", query: query),
                        context: asAsked("ORACLE-1"))
            XCTAssertTrue(sent.isEmpty, "\(query) was answered")
        }
    }
}

/// Our *encoder* against Xastir's *decoder* — the direction the query capture
/// cannot reach.
///
/// A query capture proves we can read what Xastir writes. This proves Xastir
/// can read what we write: each message below was transmitted in AXTerm's own
/// wire format and the reply is the reference implementation's acknowledgement
/// of it. An `ack` coming back is proof it found the 9-character padded
/// addressee and the message number exactly where APRS 1.01 ch.14 puts them.
final class XastirMessageRoundTripTests: XCTestCase {

    struct Capture: Decodable {
        struct Reply: Decodable {
            let infoAscii: String
            enum CodingKeys: String, CodingKey { case infoAscii = "info_ascii" }
        }
        struct Exchange: Decodable {
            let query: String        // the message body we sent
            let replies: [Reply]
        }
        let askedAs: String
        let exchanges: [Exchange]
        enum CodingKeys: String, CodingKey {
            case exchanges
            case askedAs = "asked_as"
        }
    }

    private func capture() throws -> Capture {
        let url = try XCTUnwrap(
            Bundle(for: XastirOracleTests.self)
                .url(forResource: "xastir-oracle-messages", withExtension: "json"),
            "xastir-oracle-messages.json is not in the test bundle")
        return try JSONDecoder().decode(Capture.self, from: Data(contentsOf: url))
    }

    /// Every reply in the capture, from any window.
    ///
    /// Deliberately not per-exchange. Xastir re-sends an ack at +30/+60/+120 s
    /// (`transmit_message_data_delayed`), so an acknowledgement routinely lands
    /// in a *later* query's listening window than the message that earned it.
    /// The claim being tested is "Xastir acknowledged this message", and an ack
    /// carrying the right number is that, whenever it arrived.
    private func allReplies(in capture: Capture) -> [String] {
        capture.exchanges.flatMap { ex in
            ex.replies.map { $0.infoAscii.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    /// The bodies we transmitted, so a test can assert one was sent at all.
    private func wasSent(_ body: String, in capture: Capture) -> Bool {
        capture.exchanges.contains { $0.query == body }
    }

    private func acks(for body: String, in capture: Capture) throws -> [String] {
        let ex = try XCTUnwrap(capture.exchanges.first { $0.query == body })
        return ex.replies.map { $0.infoAscii.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The reference's worked example, encoded by us, accepted by Xastir.
    func testXastirAcksOurEncodingOfTheReferenceExample() throws {
        let cap = try capture()
        XCTAssertTrue(wasSent("Testing{003", in: cap))
        let expected = APRSMessage.ackInfo(to: cap.askedAs, number: "003")
        XCTAssertTrue(allReplies(in: cap).contains(expected),
                      "expected \(expected) somewhere in the capture")
    }

    /// Both ends of the 1-to-5 character message-number range.
    func testXastirAcksTheShortestAndLongestMessageNumbers() throws {
        let cap = try capture()
        XCTAssertTrue(allReplies(in: cap)
            .contains(APRSMessage.ackInfo(to: cap.askedAs, number: "1")))
        XCTAssertTrue(allReplies(in: cap)
            .contains(APRSMessage.ackInfo(to: cap.askedAs, number: "99999")))
    }

    /// An unnumbered message solicits nothing. The only frames in that window
    /// are delayed re-acks of earlier numbered messages — never an ack of this
    /// one, because there is no number to ack.
    func testXastirDoesNotAckAnUnnumberedMessage() throws {
        let cap = try capture()
        for reply in try acks(for: "no-number-here", in: cap) {
            XCTAssertFalse(reply.contains("no-number-here"),
                           "an unnumbered message drew an ack: \(reply)")
        }
    }

    /// Our ack encoder produces exactly the bytes Xastir does, for every
    /// number it acknowledged on the rig.
    func testOurAckEncoderMatchesXastirsBytes() throws {
        let cap = try capture()
        var compared = 0
        for ex in cap.exchanges {
            guard let brace = ex.query.lastIndex(of: "{") else { continue }
            let number = String(ex.query[ex.query.index(after: brace)...])
            let ours = APRSMessage.ackInfo(to: cap.askedAs, number: number)
            if allReplies(in: cap).contains(ours) { compared += 1 }
        }
        XCTAssertGreaterThanOrEqual(compared, 3,
                                    "too few numbered messages in the capture to prove anything")
    }
}

/// The same questions, over a genuinely modulated channel.
///
/// `xastir-oracle.json` was captured over the deterministic hub, which copies
/// frames between clients. `xastir-oracle-rf.json` was captured over `rfnet`:
/// every station has its own Direwolf, all of them playing into and listening
/// to one shared audio bus, so each frame was AFSK-modulated at 1200 baud and
/// demodulated by a separate modem with its own DCD and slot timing.
///
/// The point is not that RF works — it is that the *protocol answers are the
/// same* and only the timing changes. A behaviour that differed between the two
/// would mean the hub had been lying to every other test in this file.
final class XastirRFParityTests: XCTestCase {

    private func load(_ name: String) throws -> XastirOracleTests.Oracle {
        let url = try XCTUnwrap(
            Bundle(for: XastirOracleTests.self).url(forResource: name, withExtension: "json"),
            "\(name).json is not in the test bundle")
        return try JSONDecoder().decode(XastirOracleTests.Oracle.self,
                                        from: Data(contentsOf: url))
    }

    private func answers(in oracle: XastirOracleTests.Oracle) -> [String: String] {
        var out: [String: String] = [:]
        for ex in oracle.exchanges where ex.sentVia.isEmpty {
            if let first = ex.replies.first {
                out[ex.query] = first.infoAscii.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return out
    }

    /// `?APRSD` reports which stations that Xastir has actually heard, so its
    /// content legitimately differs between two runs on two channels. Its
    /// *shape* must not.
    private static let environmentDependent = ["?APRSD"]

    /// Every answer whose content does not depend on what the station happened
    /// to hear is byte-identical on both channels.
    func testTheAnswersAreIdenticalOverRealAFSK() throws {
        let hub = answers(in: try load("xastir-oracle"))
        let rf = answers(in: try load("xastir-oracle-rf"))
        XCTAssertFalse(rf.isEmpty, "the RF capture answered nothing")
        var compared = 0
        for (query, rfAnswer) in rf where !Self.environmentDependent.contains(query) {
            XCTAssertEqual(rfAnswer, hub[query],
                           "\(query) differs between the hub and the air")
            compared += 1
        }
        XCTAssertGreaterThanOrEqual(compared, 4, "too few answers to prove parity")
    }

    /// The station list differs; the format does not.
    func testTheDirectsAnswerHasTheSameShapeOverRealAFSK() throws {
        let hub = try XCTUnwrap(answers(in: try load("xastir-oracle"))["?APRSD"])
        let rf = try XCTUnwrap(answers(in: try load("xastir-oracle-rf"))["?APRSD"])
        for answer in [hub, rf] {
            XCTAssertTrue(answer.contains(":Directs= "),
                          "expected the Directs= shape, got \(answer)")
            XCTAssertTrue(answer.contains("ORACLE-1"),
                          "we had just transmitted, so we belong in the list")
        }
    }

    /// The same queries go unanswered on both — the unimplemented set is a
    /// property of Xastir, not of a lossy channel. Worth pinning because a
    /// silent probe on RF is exactly what a channel problem also looks like.
    func testTheUnansweredSetIsTheSameOverRealAFSK() throws {
        let hub = Set(answers(in: try load("xastir-oracle")).keys)
        let rf = Set(answers(in: try load("xastir-oracle-rf")).keys)
        XCTAssertEqual(rf, hub)
    }

    /// RF costs time: TXDELAY, slot timing and modulation put the answer
    /// seconds out rather than under one. Both are far inside the 120 s ping
    /// window, which is the assumption `APRSPingTracker` rests on — this is the
    /// measurement behind calling that window generous rather than tuned.
    func testRealAFSKIsSlowerButStillWellInsideThePingWindow() throws {
        let hub = try load("xastir-oracle")
        let rf = try load("xastir-oracle-rf")

        func latency(_ o: XastirOracleTests.Oracle, _ q: String) throws -> Double {
            try XCTUnwrap(o.exchanges.first { $0.query == q && $0.sentVia.isEmpty }?
                .replies.first?.afterS)
        }
        for query in ["?VER", "?APRST"] {
            let overAir = try latency(rf, query)
            XCTAssertGreaterThan(overAir, try latency(hub, query),
                                 "\(query): modulation should cost time")
            XCTAssertLessThan(overAir, APRSPingTracker.window / 4,
                              "\(query) at \(overAir)s is uncomfortably close to the window")
        }
    }
}
