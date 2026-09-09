import XCTest
import GRDB
@testable import AXTerm

@MainActor
final class APRSMessagingServiceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var sent: [APRSOutbound] = []

    private func makeService(auto: APRSMessagingService.AutoReply = .full) throws -> APRSMessagingService {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        let svc = APRSMessagingService(store: SQLiteAPRSMessageStore(dbQueue: queue))
        svc.autoReply = auto
        svc.now = { self.clock }
        svc.send = { self.sent.append($0) }
        svc.positionInfo = { "!3934.15N/10455.05W-AXTerm" }
        svc.versionInfo = { "AXTerm 1.0" }
        svc.heardDirect = { ["W0ARP", "N0CALL-9"] }
        return svc
    }

    private func ctx(sender: String = "W0ARP", direct: Bool = true,
                     replyPath: [String] = [], destination: String = "APZAXT",
                     viaPath: [String] = []) -> APRSMessagingService.InboundContext {
        .init(sender: sender, ourCalls: ["K0EPI-7", "K0EPI"], radioID: "radio-primary",
              replyPath: replyPath, viaDirect: direct, receivedAt: clock,
              destination: destination, viaPath: viaPath)
    }

    // MARK: - Inbound messages + auto-ACK

    func testIncomingMessageIsStoredUnreadAndAutoAcked() async throws {
        let svc = try makeService()
        svc.receive(.message(addressee: "K0EPI-7", text: "hi", number: "003"), context: ctx())
        XCTAssertEqual(svc.messages.count, 1)
        XCTAssertEqual(svc.messages[0].text, "hi")
        XCTAssertEqual(svc.unreadCount, 1)
        XCTAssertEqual(sent, [APRSOutbound(info: APRSMessage.ackInfo(to: "W0ARP", number: "003"),
                                           addressee: "W0ARP", path: [], radioID: "radio-primary")])
    }

    func testDuplicateIncomingIsReAckedButNotStoredTwice() async throws {
        let svc = try makeService()
        svc.receive(.message(addressee: "K0EPI-7", text: "hi", number: "003"), context: ctx())
        svc.receive(.message(addressee: "K0EPI-7", text: "hi", number: "003"), context: ctx())
        XCTAssertEqual(svc.messages.count, 1)            // stored once
        XCTAssertEqual(sent.count, 2)                    // acked both times
    }

    func testUnnumberedMessageIsNotAcked() async throws {
        let svc = try makeService()
        svc.receive(.message(addressee: "K0EPI-7", text: "no ack please", number: nil), context: ctx())
        XCTAssertEqual(svc.messages.count, 1)
        XCTAssertTrue(sent.isEmpty)
    }

    func testManualModeStoresButDoesNotAck() async throws {
        let svc = try makeService(auto: .manual)
        svc.receive(.message(addressee: "K0EPI-7", text: "hi", number: "003"), context: ctx())
        XCTAssertEqual(svc.messages.count, 1)
        XCTAssertTrue(sent.isEmpty)
    }

    func testMessageNotAddressedToUsIsIgnored() async throws {
        let svc = try makeService()
        svc.receive(.message(addressee: "W3XYZ", text: "hi", number: "1"), context: ctx())
        XCTAssertTrue(svc.messages.isEmpty)
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Queries

    func testPositionQueryAnswersWithPosition() async throws {
        let svc = try makeService()
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?APRSP"), context: ctx())
        XCTAssertEqual(sent.first?.info, "!3934.15N/10455.05W-AXTerm")
        // The addressee records who asked — it picks the radio to answer on.
        // The frame's AX.25 destination is the tocall either way; that is the
        // transmit layer's business, not this service's.
        XCTAssertEqual(sent.first?.addressee, "W0ARP")
    }

    func testVersionQueryAnswersWithMessage() async throws {
        let svc = try makeService()
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?APRSV"), context: ctx())
        XCTAssertEqual(sent.first?.info, APRSMessage.messageInfo(to: "W0ARP", text: "AXTerm 1.0", number: nil))
    }

    // MARK: - ?APRSO

    private func object(_ name: String) -> String {
        APRSObjectReport.objectInfo(name: name, live: true, latitude: 39.6, longitude: -104.7,
                                    symbolTable: "/", symbolCode: "-", at: t0)
    }

    /// The answer is object reports, not a message about them — the same shape
    /// as the `?APRSP` position answer, so every station in range files them.
    func testObjectQueryBroadcastsOurObjects() async throws {
        let svc = try makeService()
        svc.ownObjects = { [self.object("ROADCLOSE"), self.object("AID")] }
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?APRSO"), context: ctx())
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(sent.allSatisfy { $0.info.hasPrefix(";") },
                      "an object answer is an object report, not prose: \(sent.map(\.info))")
        // Addressed so the transmit layer knows which radio to answer on, the
        // same as every other query answer.
        XCTAssertTrue(sent.allSatisfy { $0.addressee == "W0ARP" })
    }

    /// Owning none still answers. Silence is what a station that never heard of
    /// the query sends, and the asker cannot tell those apart.
    func testObjectQueryWithNothingToSendStillAnswers() async throws {
        let svc = try makeService()
        svc.ownObjects = { [] }
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?APRSO"), context: ctx())
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.info,
                       APRSMessage.messageInfo(to: "W0ARP", text: "No objects", number: nil))
    }

    /// A cap that drops objects quietly answers the question wrong while
    /// reporting success. Falsify by returning nil from `objectAnswerNote`
    /// when `total > sent`.
    func testObjectQueryCapsTheBurstAndSaysHowManyWereLeft() async throws {
        let svc = try makeService()
        let many = (1...12).map { self.object("OBJ\($0)") }
        svc.ownObjects = { many }
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?APRSO"), context: ctx())
        let objects = sent.filter { $0.info.hasPrefix(";") }
        XCTAssertEqual(objects.count, APRSMessagingService.objectsPerQueryLimit)
        XCTAssertEqual(sent.last?.info,
                       APRSMessage.messageInfo(to: "W0ARP", text: "8 of 12 objects sent",
                                               number: nil))
    }

    func testObjectQueryIsNotAnsweredWhenAutoReplyIsOff() async throws {
        let svc = try makeService(auto: .ackOnly)
        svc.ownObjects = { [self.object("ROADCLOSE")] }
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?APRSO"), context: ctx())
        XCTAssertTrue(sent.isEmpty)
    }

    func testDirectsQueryListsHeardDirect() async throws {
        let svc = try makeService()
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?APRSD"), context: ctx())
        XCTAssertEqual(sent.first?.info, APRSMessage.messageInfo(to: "W0ARP", text: "Directs= W0ARP N0CALL-9", number: nil))
    }

    /// A list too long for one message continues into the next rather than
    /// being cut. Xastir does the same — on the rig, eight stations came back
    /// as two `Directs=` messages — and the alternative is worse than a short
    /// answer: `String.prefix(67)` can slice a callsign in half, and `W0ARP-10`
    /// arriving as `W0AR` names a station that was never heard.
    func testALongDirectsListContinuesIntoASecondMessage() throws {
        let calls = ["KE0ABCD-15", "W0ARP-10", "N0CALL-9", "K0EPI-7", "AD1CT",
                     "KK0X-10", "N2XGL-1", "WT0R-9"]
        let lines = APRSMessagingService.directsAnswers(calls)
        XCTAssertGreaterThan(lines.count, 1, "this list does not fit in one message")
        for line in lines {
            XCTAssertTrue(line.hasPrefix("Directs="), line)
            XCTAssertLessThanOrEqual(line.count, APRSMessage.maxTextLength, line)
        }
        // Every station named exactly once, and none of them mangled.
        let named = lines.flatMap { $0.dropFirst("Directs=".count).split(separator: " ") }
            .map(String.init)
        XCTAssertEqual(named, calls, "a callsign was dropped, split or reordered")
    }

    /// The leading space belongs to each callsign, not to the separator: that
    /// is how Xastir builds the string and the first space is the one a naive
    /// `joined(separator:)` loses.
    func testEveryCallsignCarriesItsOwnLeadingSpace() throws {
        XCTAssertEqual(APRSMessagingService.directsAnswers(["W0ARP"]), ["Directs= W0ARP"])
        XCTAssertEqual(APRSMessagingService.directsAnswers([]), ["Directs="],
                       "hearing nobody is an answer, not silence")
    }

    /// A busy station hears more than anybody asking wants transmitted at
    /// them, so the answer stops rather than filling the channel.
    func testTheDirectsAnswerIsBounded() throws {
        let many = (1...60).map { "K0TEST-\($0)" }
        XCTAssertEqual(APRSMessagingService.directsAnswers(many).count,
                       APRSMessagingService.directsMessageLimit)
    }

    /// `?APRST` asks how the query reached us, not where we are. Answering it
    /// with a beacon answers `?APRSP` instead.
    ///
    /// The format quotes the whole received path — destination included, and
    /// every digipeater whether or not it was used. Verified against a real
    /// Xastir 2.1.8 on the test rig, which is how the destination was found to
    /// be missing from the first version of this
    /// (`AXTermTests/Fixtures/xastir-oracle.json`).
    func testTraceQueryAnswersWithThePathTheQueryTook() async throws {
        let svc = try makeService()
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?APRST"),
                    context: ctx(direct: false, replyPath: ["WIDE1", "AD1CT"],
                                 destination: "APZAXT",
                                 viaPath: ["AD1CT", "WIDE1"]))
        XCTAssertEqual(sent.first?.info,
                       APRSMessage.messageInfo(to: "W0ARP",
                                               text: "PATH= W0ARP>APZAXT,AD1CT,WIDE1",
                                               number: nil))
    }

    /// Heard direct: just the sender and the destination, no digipeaters.
    func testTraceQueryHeardDirectQuotesOnlyTheDestination() async throws {
        let svc = try makeService()
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?APRST"), context: ctx())
        XCTAssertEqual(sent.first?.info,
                       APRSMessage.messageInfo(to: "W0ARP", text: "PATH= W0ARP>APZAXT",
                                               number: nil))
    }

    /// `?PING?` is the same query under its other name, and Xastir treats the
    /// two identically.
    func testPingQueryIsTheSameTrace() async throws {
        let svc = try makeService()
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?PING?"), context: ctx())
        XCTAssertEqual(sent.first?.info,
                       APRSMessage.messageInfo(to: "W0ARP", text: "PATH= W0ARP>APZAXT",
                                               number: nil))
    }

    func testQueriesAreNotAnsweredInAckOnlyMode() async throws {
        let svc = try makeService(auto: .ackOnly)
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?APRSP"), context: ctx())
        XCTAssertTrue(sent.isEmpty)                       // logged, not answered
        XCTAssertEqual(svc.messages.count, 1)
    }

    // MARK: - Outbound + ACK + retry

    func testSendMessageTracksForAckAndReachabilityResolves() async throws {
        let svc = try makeService()
        let rec = svc.sendMessage(to: "W0ARP", text: "you there?", from: "K0EPI-7",
                                  path: [], radioID: "radio-primary")
        XCTAssertEqual(sent.first?.info,
                       APRSMessage.messageInfo(to: "W0ARP", text: "you there?", number: rec.number))
        XCTAssertEqual(svc.messages[0].state, .sent)
        XCTAssertFalse(svc.reachability(of: "W0ARP").confirmed)

        // Their ack, heard direct, confirms reachability and stops retries.
        clock = t(20)
        svc.receive(.ack(addressee: "K0EPI-7", number: rec.number!), context: ctx(direct: true))
        XCTAssertEqual(svc.messages[0].state, .acked)
        let reach = svc.reachability(of: "W0ARP")
        XCTAssertTrue(reach.confirmed)
        XCTAssertTrue(reach.direct)
    }

    func testRetryLadderResendsThenFails() async throws {
        let svc = try makeService()
        let rec = svc.sendMessage(to: "W0ARP", text: "ping", from: "K0EPI-7",
                                  path: ["WIDE1-1"], radioID: "radio-primary")
        XCTAssertEqual(sent.count, 1)

        // Nothing due yet.
        clock = t(10); svc.runRetries()
        XCTAssertEqual(sent.count, 1)

        // First retry due at +30, and it reuses the stored path.
        clock = t(31); svc.runRetries()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.path, ["WIDE1-1"])
        XCTAssertEqual(svc.messages[0].attempts, 2)

        // Drive through the rest of the ladder (delays 60,120,240,480).
        clock = t(31 + 60);  svc.runRetries()   // attempt 3
        clock = t(31 + 180); svc.runRetries()   // attempt 4
        clock = t(31 + 420); svc.runRetries()   // attempt 5
        XCTAssertEqual(svc.messages[0].attempts, 5)
        // One more due sweep past the ladder marks it failed, no new send.
        let before = sent.count
        clock = t(31 + 420 + 480); svc.runRetries()
        XCTAssertEqual(svc.messages[0].state, .failed)
        XCTAssertEqual(sent.count, before)
        XCTAssertNil(try XCTUnwrap(svc.messages.first).nextRetryAt)

        // A late ack against a failed message is ignored (no crash, no revive).
        svc.receive(.ack(addressee: "K0EPI-7", number: rec.number!), context: ctx())
        XCTAssertEqual(svc.messages[0].state, .failed)
    }

    func testRejectFailsTheOutgoingMessage() async throws {
        let svc = try makeService()
        let rec = svc.sendMessage(to: "W0ARP", text: "hi", from: "K0EPI-7",
                                  path: [], radioID: "radio-primary")
        svc.receive(.reject(addressee: "K0EPI-7", number: rec.number!), context: ctx())
        XCTAssertEqual(svc.messages[0].state, .failed)
    }

    // MARK: - Bulletins

    func testBulletinStoredAndReissueUpdatesInPlace() async throws {
        let svc = try makeService()
        svc.receive(.bulletin(id: "BLN1", text: "Net 8pm"), context: ctx(sender: "W0TX"))
        svc.receive(.bulletin(id: "BLN1", text: "Net 9pm"), context: ctx(sender: "W0TX"))
        let blns = svc.messages.filter { $0.kind == .bulletin }
        XCTAssertEqual(blns.count, 1)
        XCTAssertEqual(blns[0].text, "Net 9pm")
    }

    // MARK: - General queries

    /// A general query is unaddressed, so every station in earshot answers the
    /// same frame at the same moment. Bruninga's rule — and Xastir's
    /// implementation of it — spreads the answers over a random 0–120 s;
    /// answering instantly guarantees a collision with everyone who did the
    /// same.
    func testAGeneralQueryIsAnsweredOnlyAfterTheDelay() async throws {
        let svc = try makeService()
        svc.receive(.generalQuery(APRSMessage.generalQueryAllInfo), context: ctx())
        XCTAssertTrue(sent.isEmpty, "an instant answer is a guaranteed collision")

        clock = t(APRSMessagingService.generalQueryWindow + 1)
        svc.runRetries()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.info, "!3934.15N/10455.05W-AXTerm")
    }

    /// A second query while an answer is pending must not queue a second
    /// answer: one posit serves every station that asked.
    func testASecondQueryDoesNotQueueASecondAnswer() async throws {
        let svc = try makeService()
        svc.receive(.generalQuery(APRSMessage.generalQueryAllInfo), context: ctx())
        svc.receive(.generalQuery(APRSMessage.generalQueryAllInfo), context: ctx(sender: "N0CALL-9"))
        clock = t(APRSMessagingService.generalQueryWindow + 1)
        svc.runRetries()
        XCTAssertEqual(sent.count, 1)
    }

    /// Our own query coming back off a digipeater: answering it would be a
    /// station holding a conversation with itself.
    func testOurOwnQueryIsNotAnswered() async throws {
        let svc = try makeService()
        svc.receive(.generalQuery(APRSMessage.generalQueryAllInfo), context: ctx(sender: "K0EPI-7"))
        clock = t(APRSMessagingService.generalQueryWindow + 1)
        svc.runRetries()
        XCTAssertTrue(sent.isEmpty)
    }

    /// The spec writes query tokens in uppercase. Xastir refuses any other
    /// case as an illegal query rather than guessing what was meant.
    func testALowercaseQueryIsNotAnswered() async throws {
        let svc = try makeService()
        svc.receive(.generalQuery("?aprs?"), context: ctx())
        clock = t(APRSMessagingService.generalQueryWindow + 1)
        svc.runRetries()
        XCTAssertTrue(sent.isEmpty)
    }

    /// `?WX?` asks for a weather report; this station is not a weather
    /// station, and answering with a position would be answering a question
    /// nobody asked. Xastir leaves it unimplemented for the same reason.
    func testAWeatherQueryIsNotAnsweredWithAPosition() async throws {
        let svc = try makeService()
        svc.receive(.generalQuery("?WX?"), context: ctx())
        clock = t(APRSMessagingService.generalQueryWindow + 1)
        svc.runRetries()
        XCTAssertTrue(sent.isEmpty)
    }

    func testManualModeAnswersNoGeneralQuery() async throws {
        let svc = try makeService(auto: .manual)
        svc.receive(.generalQuery(APRSMessage.generalQueryAllInfo), context: ctx())
        clock = t(APRSMessagingService.generalQueryWindow + 1)
        svc.runRetries()
        XCTAssertTrue(sent.isEmpty)
    }

    /// A directed query is aimed at us alone, so there is nobody to collide
    /// with and no reason to wait — Xastir answers it immediately too.
    func testADirectedQueryIsStillAnsweredAtOnce() async throws {
        let svc = try makeService()
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?APRSP"), context: ctx())
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.info, "!3934.15N/10455.05W-AXTerm")
    }

    func testALowercaseDirectedQueryIsNotAnswered() async throws {
        let svc = try makeService()
        svc.receive(.directedQuery(addressee: "K0EPI-7", query: "?aprsp"), context: ctx())
        XCTAssertTrue(sent.isEmpty)
    }
}
