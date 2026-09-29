import XCTest
@testable import AXTerm

/// Telling an answer from a coincidence.
///
/// A reply to `?APRSP` is an ordinary broadcast position report — no
/// addressee, no reference to the query, identical in kind to the beacon the
/// station was going to send anyway. Timing is the only evidence there is.
final class APRSAnswerEvidenceTests: XCTestCase {

    /// A digipeater that beacons every ten minutes, transmitting fifteen
    /// seconds after the query: unlikely to be luck.
    func testASlowStationRespondingQuicklyIsEvidence() {
        XCTAssertEqual(APRSAnswerEvidence.verdict(elapsed: 15, typicalInterval: 600), .answered)
    }

    /// A tracker beaconing every few seconds lands in any window and proves
    /// nothing by it. This is the case that made the old probe over-report:
    /// KB7OKL-1 was transmitting three times a minute before the query and
    /// three times a minute after it.
    func testAFastBeaconProvesNothing() {
        XCTAssertEqual(APRSAnswerEvidence.verdict(elapsed: 10, typicalInterval: 5), .unproven)
        XCTAssertEqual(APRSAnswerEvidence.verdict(elapsed: 30, typicalInterval: 60), .unproven)
    }

    /// Not knowing a station's habits is not evidence either way.
    func testAnUnknownCadenceIsNotEvidence() {
        XCTAssertEqual(APRSAnswerEvidence.verdict(elapsed: 5, typicalInterval: nil), .unproven)
    }

    func testTheBoundaryIsTheImprobabilityFactor() {
        let elapsed: TimeInterval = 20
        let exactly = elapsed * APRSAnswerEvidence.improbabilityFactor
        XCTAssertEqual(APRSAnswerEvidence.verdict(elapsed: elapsed, typicalInterval: exactly),
                       .answered)
        XCTAssertEqual(APRSAnswerEvidence.verdict(elapsed: elapsed, typicalInterval: exactly - 1),
                       .unproven)
    }

    // MARK: - Cadence

    private func times(_ gaps: [TimeInterval]) -> [Date] {
        var t = Date(timeIntervalSince1970: 1_780_000_000)
        var out = [t]
        for gap in gaps {
            t = t.addingTimeInterval(gap)
            out.append(t)
        }
        return out
    }

    func testTheCadenceIsTheMedianGap() {
        XCTAssertEqual(APRSAnswerEvidence.typicalInterval(of: times([60, 60, 60])), 60)
    }

    /// The median rather than the mean: one long silence while a mobile is
    /// parked would drag an average out until every later beacon looked like
    /// an answer.
    func testOneLongSilenceDoesNotSetTheCadence() {
        let interval = APRSAnswerEvidence.typicalInterval(of: times([30, 30, 30, 3600]))
        XCTAssertEqual(interval, 30, "the median ignores the outlier the mean would follow")
    }

    /// Two sightings are one gap, which is a coincidence rather than a habit.
    func testTooFewSightingsIsNoCadence() {
        XCTAssertNil(APRSAnswerEvidence.typicalInterval(of: times([60])))
    }
}

/// What became of a ping.
@MainActor
final class APRSPingTrackerTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 1_780_000_000)

    private func tracker(interval: TimeInterval? = 600) -> APRSPingTracker {
        let t = APRSPingTracker()
        t.now = { self.clock }
        t.beaconInterval = { _ in interval }
        return t
    }

    func testAPingStartsWaiting() async throws {
        let t = tracker()
        t.record(ping: "W0ARP", query: "?APRSP")
        XCTAssertEqual(t.outcome(for: "W0ARP")?.outcome, .waiting)
    }

    /// A station that addresses us has proved it hears us. This is the only
    /// unambiguous evidence APRS offers — and it is evidence of reception,
    /// not necessarily of an answer. See `testAMessageIsNotAnAnswerToAQuery\
    /// ThatIsAnsweredWithABroadcast`.
    func testADirectedReplyIsProof() async throws {
        let t = tracker()
        t.record(ping: "W0ARP", query: "?APRSP")
        t.noteDirectedReply(from: "w0arp")
        XCTAssertEqual(t.outcome(for: "W0ARP")?.outcome, .confirmed)
    }

    // MARK: - Answering versus merely addressing us

    /// K0EPI-4, 2026-09-09. `?APRSP` and `?VER` went out; the station never
    /// answered either, and its operator typed "Howdy" 40 s later. The map
    /// reported "Answered us directly. It heard the ping."
    ///
    /// `?APRSP` is answered with an ordinary broadcast position (APRS 1.01
    /// ch.15), never with a message, so a message arriving during one cannot
    /// be its answer whatever else it proves.
    func testAMessageIsNotAnAnswerToAQueryThatIsAnsweredWithABroadcast() async throws {
        let t = tracker()
        t.record(ping: "K0EPI-4", query: "?APRSP")
        t.noteDirectedReply(from: "K0EPI-4")
        let ping = try XCTUnwrap(t.outcome(for: "K0EPI-4"))
        XCTAssertEqual(ping.reply, .addressedUs)
        // The reception finding is kept: it did address us, and that is worth
        // more to the operator than the unanswered query.
        XCTAssertEqual(ping.outcome, .confirmed, "addressing us still proves reception")

        let line = APRSPingPresentation.line(ping)
        XCTAssertFalse(line.lowercased().hasPrefix("answered"),
                       "a hand-typed message is not an answer to \(ping.query): \(line)")
        XCTAssertTrue(line.contains("not an answer to ?APRSP"), line)
        XCTAssertTrue(line.contains("hears us"), "reception is still reported: \(line)")
    }

    /// The other half, so the rule is not merely "never say answered":
    /// `?VER` *is* answered with a message, so a message answers it.
    func testAMessageIsTheAnswerToAQueryThatIsAnsweredWithAMessage() async throws {
        let t = tracker()
        t.record(ping: "W0ARP", query: "?VER")
        t.noteDirectedReply(from: "W0ARP")
        let ping = try XCTUnwrap(t.outcome(for: "W0ARP"))
        XCTAssertEqual(ping.reply, .answeredQuery)
        XCTAssertTrue(APRSPingPresentation.line(ping).hasPrefix("Answered"),
                      APRSPingPresentation.line(ping))
    }

    /// Every query AXTerm can send is classified, so no ping can land in the
    /// unrecognised-token fallback by accident.
    func testEveryQueryWeCanSendIsClassified() async throws {
        for query in APRSDirectedQuery.allCases {
            let t = tracker()
            t.record(ping: "W0ARP", query: query.token)
            t.noteDirectedReply(from: "W0ARP")
            let ping = try XCTUnwrap(t.outcome(for: "W0ARP"))
            XCTAssertEqual(ping.reply,
                           query.isProvable ? .answeredQuery : .addressedUs,
                           query.token)
        }
    }

    func testAnImprobablyEarlyTransmissionIsLikely() async throws {
        let t = tracker(interval: 600)
        t.record(ping: "W0ARP", query: "?APRSP")
        clock = clock.addingTimeInterval(10)
        t.noteTransmission(from: "W0ARP")
        XCTAssertEqual(t.outcome(for: "W0ARP")?.outcome, .likely)
    }

    /// The case the whole thing exists for: a tracker beaconing constantly
    /// must not be reported as having answered.
    func testAFastBeaconIsNotAnAnswer() async throws {
        let t = tracker(interval: 5)
        t.record(ping: "KB7OKL-1", query: "?APRSP")
        clock = clock.addingTimeInterval(10)
        t.noteTransmission(from: "KB7OKL-1")
        XCTAssertEqual(t.outcome(for: "KB7OKL-1")?.outcome, .waiting)
    }

    /// Proof outranks inference: a directed reply after a lucky-looking
    /// beacon upgrades the verdict rather than being ignored.
    func testProofUpgradesALikelyAnswer() async throws {
        let t = tracker(interval: 600)
        t.record(ping: "W0ARP", query: "?APRSP")
        clock = clock.addingTimeInterval(10)
        t.noteTransmission(from: "W0ARP")
        t.noteDirectedReply(from: "W0ARP")
        XCTAssertEqual(t.outcome(for: "W0ARP")?.outcome, .confirmed)
    }

    /// AD1CT, 2026-09-09: it repeated the ping frame on the air and then
    /// never answered it. Digipeating is an AX.25-layer job and answering a
    /// query is an APRS-application one, so this is ordinary rather than
    /// contradictory — and it is the difference between "no answer" and "it
    /// cannot hear you", which is the whole reason to record it.
    func testADigipeatProvesReceptionWithoutBeingAnAnswer() async throws {
        let t = tracker()
        t.record(ping: "AD1CT", query: "?APRSP")
        clock = clock.addingTimeInterval(12)
        t.noteDigipeat(by: "ad1ct")
        let ping = try XCTUnwrap(t.outcome(for: "AD1CT"))
        XCTAssertTrue(ping.heardUs)
        XCTAssertEqual(ping.outcome, .waiting, "repeating a frame is not answering it")
    }

    /// The window closing does not un-prove the link: the row has to keep
    /// saying "it hears you" once it goes silent, or the fact is lost exactly
    /// when it matters.
    func testProvenReceptionSurvivesTheWindow() async throws {
        let t = tracker()
        t.record(ping: "AD1CT", query: "?APRSP")
        clock = clock.addingTimeInterval(12)
        t.noteDigipeat(by: "AD1CT")
        clock = clock.addingTimeInterval(APRSPingTracker.window)
        t.expire()
        let ping = try XCTUnwrap(t.outcome(for: "AD1CT"))
        XCTAssertEqual(ping.outcome, .silent)
        XCTAssertTrue(ping.heardUs)
    }

    /// A digipeat long after the ping proves the station hears us, but not
    /// that it heard *this*, and the row speaks about this one.
    func testADigipeatAfterTheWindowIsNotAttributed() async throws {
        let t = tracker()
        t.record(ping: "AD1CT", query: "?APRSP")
        clock = clock.addingTimeInterval(APRSPingTracker.window + 1)
        t.noteDigipeat(by: "AD1CT")
        XCTAssertEqual(t.outcome(for: "AD1CT")?.heardUs, false)
    }

    /// K5RHD-10 repeated the ping we sent to AD1CT. That says nothing about
    /// AD1CT, and crediting it would turn "somebody heard us" into "they did".
    func testOnlyTheRepeatingStationIsCredited() async throws {
        let t = tracker()
        t.record(ping: "AD1CT", query: "?APRSP")
        clock = clock.addingTimeInterval(5)
        t.noteDigipeat(by: "K5RHD-10")
        XCTAssertEqual(t.outcome(for: "AD1CT")?.heardUs, false)
    }

    /// AD1CT, 2026-09-09 again: it digipeats the operator's WIDE traffic all
    /// day, so it plainly receives us, but the queries went out *direct* and a
    /// direct frame carries no path for a digipeater to repeat. The reception
    /// fact has to outlive the ping or the app forgets what it has seen.
    func testRepeatingUsIsRememberedApartFromAnyPing() async throws {
        let t = tracker()
        t.noteDigipeat(by: "ad1ct")
        XCTAssertEqual(t.repeatedUs("AD1CT"), clock)
        XCTAssertNil(t.outcome(for: "AD1CT"), "no ping was sent; this is a fact about the link")
    }

    /// The record keeps the most recent sighting, not the first.
    func testTheLatestRepeatWins() async throws {
        let t = tracker()
        t.noteDigipeat(by: "AD1CT")
        let later = clock.addingTimeInterval(600)
        t.noteDigipeat(by: "AD1CT", at: later)
        t.noteDigipeat(by: "AD1CT", at: clock)          // an out-of-order arrival
        XCTAssertEqual(t.repeatedUs("AD1CT"), later)
    }

    /// A digipeat outside the ping's window still proves reception even though
    /// it says nothing about that ping.
    func testALateRepeatStillCountsAsReception() async throws {
        let t = tracker()
        t.record(ping: "AD1CT", query: "?APRSP")
        clock = clock.addingTimeInterval(APRSPingTracker.window + 1)
        t.noteDigipeat(by: "AD1CT")
        XCTAssertEqual(t.outcome(for: "AD1CT")?.heardUs, false, "not this ping")
        XCTAssertNotNil(t.repeatedUs("AD1CT"), "but the link is proven")
    }

    /// The reach travels with the ping, because it decides whether the absence
    /// of digipeat evidence means anything.
    func testAPingRemembersHowFarItWasSent() async throws {
        let t = tracker()
        t.record(ping: "AD1CT", query: "?VER", reach: .wide)
        XCTAssertEqual(t.outcome(for: "AD1CT")?.reach, .wide)
        t.record(ping: "AD1CT", query: "?VER")
        XCTAssertEqual(t.outcome(for: "AD1CT")?.reach, .direct, "direct is the default")
    }

    /// A ping that stays "waiting" for ever is the same silence it was
    /// before, dressed as progress.
    func testAnUnansweredPingGoesSilent() async throws {
        let t = tracker()
        t.record(ping: "W0ARP", query: "?APRSP")
        clock = clock.addingTimeInterval(APRSPingTracker.window + 1)
        t.expire()
        XCTAssertEqual(t.outcome(for: "W0ARP")?.outcome, .silent)
    }

    func testATransmissionAfterTheWindowChangesNothing() async throws {
        let t = tracker()
        t.record(ping: "W0ARP", query: "?APRSP")
        clock = clock.addingTimeInterval(APRSPingTracker.window + 1)
        t.expire()
        t.noteTransmission(from: "W0ARP")
        XCTAssertEqual(t.outcome(for: "W0ARP")?.outcome, .silent)
    }

    /// Pinging again replaces the old result rather than stacking a second
    /// entry for the same station.
    func testPingingAgainStartsOver() async throws {
        let t = tracker()
        t.record(ping: "W0ARP", query: "?APRSP")
        t.noteDirectedReply(from: "W0ARP")
        t.record(ping: "W0ARP", query: "?APRSP")
        XCTAssertEqual(t.pings.count, 1)
        XCTAssertEqual(t.outcome(for: "W0ARP")?.outcome, .waiting)
    }
}
