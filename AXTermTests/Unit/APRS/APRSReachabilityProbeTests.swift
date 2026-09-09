import XCTest
@testable import AXTerm

@MainActor
final class APRSReachabilityProbeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var floods = 0
    private var canTransmit = true
    private var heard: [String: APRSReachabilityProbe.HeardStation] = [:]

    private func station(_ call: String, at: Date?, direct: Bool,
                         _ cls: APRSStationClass) -> APRSReachabilityProbe.HeardStation {
        APRSReachabilityProbe.HeardStation(callsign: call, lastHeard: at,
                                           direct: direct, stationClass: cls)
    }

    /// The last question actually put on the air, so a test can assert that
    /// picking "weather" transmits `?WX?` and not the generic query.
    private var lastQuery: APRSGeneralQuery?
    /// How far the last question was asked, so a test can assert that a wide
    /// query is transmitted with a path and the earshot probe without one.
    private var lastReach: APRSProbeReach?

    private func makeProbe() -> APRSReachabilityProbe {
        let p = APRSReachabilityProbe()
        p.now = { self.clock }
        p.floodQuery = { query, reach in
            self.floods += 1
            self.lastQuery = query
            self.lastReach = reach
            return self.canTransmit
        }
        p.aprsStations = { Array(self.heard.values) }
        return p
    }

    func testNoConnectedRadioReportsTransmitFailedAndDoesNotListen() async throws {
        canTransmit = false
        heard["W0ARP"] = station("W0ARP", at: t(-30), direct: true, .fixed)
        let p = makeProbe()
        p.start(scope: .all)
        XCTAssertEqual(floods, 1)               // it tried
        XCTAssertTrue(p.transmitFailed)
        XCTAssertNil(p.sentAt)                  // never counts a later hear as a reply
        XCTAssertEqual(p.status, .idle)
        // A station heard afterward is NOT mistaken for a reply to a query we
        // never sent.
        heard["W0ARP"] = station("W0ARP", at: t(5), direct: true, .fixed)
        clock = t(6); p.tick()
        XCTAssertTrue(p.responders.isEmpty)
    }

    func testStartFloodsExactlyOnce() async throws {
        // A baseline of APRS stations, all heard before we start.
        heard["W0ARP"] = station("W0ARP", at: t(-30), direct: true, .fixed)
        heard["N0CALL-9"] = station("N0CALL-9", at: t(-20), direct: false, .moving)
        let p = makeProbe()
        p.start(scope: .all)
        XCTAssertEqual(floods, 1)               // one general query, not per-station
        XCTAssertEqual(p.status, .listening)
        XCTAssertTrue(p.responders.isEmpty)     // nobody has answered yet

        // Ticks never re-flood.
        clock = t(4); p.tick()
        clock = t(8); p.tick()
        XCTAssertEqual(floods, 1)
    }

    func testResponderIsCountedDirectOrDigipeated() async throws {
        heard["W0ARP"] = station("W0ARP", at: t(-30), direct: true, .fixed)
        heard["N0CALL-9"] = station("N0CALL-9", at: t(-20), direct: false, .moving)
        let p = makeProbe()
        p.start(scope: .all)                    // flooded at t0

        // Both answer after the flood: W0ARP direct, N0CALL-9 via a digi.
        heard["W0ARP"] = station("W0ARP", at: t(8), direct: true, .fixed)
        heard["N0CALL-9"] = station("N0CALL-9", at: t(9), direct: false, .moving)
        clock = t(10); p.tick()

        XCTAssertEqual(Set(p.responders.map(\.callsign)), ["W0ARP", "N0CALL-9"])
        XCTAssertEqual(p.scopedDirectResponders.map(\.callsign), ["W0ARP"])
    }

    func testAStationHeardOnlyBeforeTheFloodIsNotAReply() async throws {
        heard["W0ARP"] = station("W0ARP", at: t(-30), direct: true, .fixed)
        let p = makeProbe()
        p.start(scope: .all)                    // flooded at t0
        clock = t(5); p.tick()
        XCTAssertTrue(p.responders.isEmpty)
        // It was out there before, so it's on the silent list.
        XCTAssertEqual(p.scopedSilent, ["W0ARP"])
    }

    func testScopeFiltersResultsWithoutReflooding() async throws {
        heard["DIGI"] = station("DIGI", at: t(-5), direct: true, .infrastructure)
        heard["ROVER-9"] = station("ROVER-9", at: t(-5), direct: true, .moving)
        let p = makeProbe()
        p.start(scope: .all)                    // flooded once

        // Both answer.
        heard["DIGI"] = station("DIGI", at: t(6), direct: true, .infrastructure)
        heard["ROVER-9"] = station("ROVER-9", at: t(7), direct: false, .moving)
        clock = t(8); p.tick()
        XCTAssertEqual(Set(p.scopedResponders.map(\.callsign)), ["DIGI", "ROVER-9"])

        // Narrowing the scope re-filters the same results — no new flood.
        p.scope = .infrastructure
        XCTAssertEqual(p.scopedResponders.map(\.callsign), ["DIGI"])
        p.scope = .moving
        XCTAssertEqual(p.scopedResponders.map(\.callsign), ["ROVER-9"])
        XCTAssertEqual(floods, 1)
    }

    func testWindowElapsesAndTheSweepFinishes() async throws {
        heard["W0ARP"] = station("W0ARP", at: t(-30), direct: true, .fixed)
        let p = makeProbe()
        p.start(scope: .all)
        clock = t(5); p.tick()
        XCTAssertEqual(p.status, .listening)    // still within the window
        clock = t0.addingTimeInterval(p.responseWindow + 1); p.tick()
        XCTAssertEqual(p.status, .done)
        XCTAssertTrue(p.responders.isEmpty)
        XCTAssertEqual(p.scopedSilent, ["W0ARP"])
    }

    func testFloodHappensEvenWithNoBaselineStations() async throws {
        let p = makeProbe()                      // heard is empty
        p.start(scope: .all)
        XCTAssertEqual(floods, 1)                // we still ask the channel
        XCTAssertEqual(p.status, .listening)
        XCTAssertTrue(p.scopedSilent.isEmpty)

        // A station we'd never heard answers the flood — a first contact.
        heard["NEW-1"] = station("NEW-1", at: t(4), direct: true, .fixed)
        clock = t(5); p.tick()
        XCTAssertEqual(p.scopedResponders.map(\.callsign), ["NEW-1"])
    }

    // MARK: - Which question goes on the air

    /// The flood is one transmission whatever is asked, and the string that
    /// goes out has to be the one the specification defines — a station only
    /// answers a query it recognises.
    func testTheChosenQueryIsTheOneTransmitted() async throws {
        let p = makeProbe()
        p.start(query: .weather)
        XCTAssertEqual(floods, 1, "one transmission, not one per station")
        XCTAssertEqual(lastQuery, .weather)
        XCTAssertEqual(lastQuery?.rawValue, "?WX?")
        XCTAssertEqual(p.query, .weather, "the results say which question they answer")
    }

    func testTheDefaultQueryIsTheGeneralOne() async throws {
        let p = makeProbe()
        p.start()
        XCTAssertEqual(lastQuery, .all)
        XCTAssertEqual(lastQuery?.rawValue, "?APRS?")
    }

    /// Asking a second question during the reply window supersedes the first
    /// rather than being refused: the control is not disabled while listening.
    func testAskingAgainWhileListeningStartsTheNewQuery() async throws {
        let p = makeProbe()
        p.start(query: .position)
        XCTAssertEqual(p.status, .listening)
        p.start(query: .objects)
        XCTAssertEqual(floods, 2)
        XCTAssertEqual(p.query, .objects)
        XCTAssertEqual(p.status, .listening)
    }

    /// Every query string is from the specification. Typos here are silent:
    /// stations simply never answer.
    func testQueryStringsAreTheSpecifiedOnes() {
        XCTAssertEqual(APRSGeneralQuery.all.rawValue, "?APRS?")
        XCTAssertEqual(APRSGeneralQuery.position.rawValue, "?APRSP")
        XCTAssertEqual(APRSGeneralQuery.weather.rawValue, "?WX?")
        XCTAssertEqual(APRSGeneralQuery.status.rawValue, "?APRSS")
        XCTAssertEqual(APRSGeneralQuery.objects.rawValue, "?APRSO")
        XCTAssertEqual(APRSGeneralQuery.directHeard.rawValue, "?APRSD")
    }

    // MARK: - A send that was accepted and then failed to key

    /// The log3 failure: the IC-705 accepted the frame, then CI-V PTT timed
    /// out. `floodQuery` had already returned true, so the probe listened for
    /// two minutes for replies to a query that never went on the air.
    func testAFaultJustAfterTransmittingEndsTheListenAndSaysWhy() async throws {
        heard["W0ARP"] = station("W0ARP", at: t(-30), direct: true, .fixed)
        let p = makeProbe()
        p.start(scope: .all)
        XCTAssertEqual(p.status, .listening, "the queued send looked fine")

        clock = t(2)
        p.transmitDidFail("PTT failed: timeout(command: 28)")

        XCTAssertTrue(p.transmitFailed)
        XCTAssertEqual(p.transmitFailureReason, "PTT failed: timeout(command: 28)")
        XCTAssertEqual(p.status, .idle, "stop listening for replies that cannot come")
        XCTAssertNil(p.sentAt)

        // And nothing heard afterwards is mistaken for a reply.
        heard["W0ARP"] = station("W0ARP", at: t(10), direct: true, .fixed)
        clock = t(11); p.tick()
        XCTAssertTrue(p.responders.isEmpty)
    }

    /// A fault long after the transmission is somebody else's problem — a
    /// beacon on another radio, say. It must not void a query that did go out.
    func testAFaultLongAfterTheTransmissionIsNotOurs() async throws {
        let p = makeProbe()
        p.start(scope: .all)
        clock = t(p.transmitFaultWindow + 1)
        p.transmitDidFail("PTT failed: timeout(command: 28)")
        XCTAssertFalse(p.transmitFailed)
        XCTAssertEqual(p.status, .listening)
        XCTAssertNotNil(p.sentAt)
    }

    /// Nor does a fault while nothing is being probed disturb a finished run.
    func testAFaultWhenNotListeningIsIgnored() async throws {
        let p = makeProbe()
        p.start(scope: .all)
        clock = t(p.responseWindow + 1)
        p.tick()
        XCTAssertEqual(p.status, .done)
        p.transmitDidFail("PTT failed: timeout(command: 28)")
        XCTAssertFalse(p.transmitFailed, "the query did go out; the run is over")
        XCTAssertEqual(p.status, .done)
    }

    /// The two failures are distinguishable, because the operator fixes them
    /// in different places.
    func testNoRadioAndAFailedKeyAreToldApart() async throws {
        canTransmit = false
        let noRadio = makeProbe()
        noRadio.start(scope: .all)
        XCTAssertTrue(noRadio.transmitFailed)
        XCTAssertNil(noRadio.transmitFailureReason, "no radio took it — nothing reported a reason")

        canTransmit = true
        let failedKey = makeProbe()
        failedKey.start(scope: .all)
        clock = t(1)
        failedKey.transmitDidFail("PTT was not confirmed within 2 s; frames dropped")
        XCTAssertTrue(failedKey.transmitFailed)
        XCTAssertNotNil(failedKey.transmitFailureReason)
    }

    // MARK: - Reach

    /// The default is direct, because the probe's headline question is "who
    /// can hear me" and only a direct query answers it: a digipeated one is
    /// answered by stations that cannot hear this one at all.
    func testTheDefaultQuestionIsAskedDirect() async throws {
        heard["W0ARP"] = station("W0ARP", at: t(-30), direct: true, .fixed)
        let p = makeProbe()
        p.start(query: .all, scope: .all)
        XCTAssertEqual(lastReach, .direct)
        XCTAssertEqual(p.reach, .direct)
    }

    /// Asking wide is Xastir's behaviour — it transmits general queries on the
    /// interface's own UNPROTO path — and the results have to record it, or
    /// they claim earshot they did not measure.
    func testAWideQuestionIsRecordedAsSuch() async throws {
        heard["W0ARP"] = station("W0ARP", at: t(-30), direct: true, .fixed)
        let p = makeProbe()
        p.start(query: .weather, scope: .all, reach: .wide)
        XCTAssertEqual(lastReach, .wide)
        XCTAssertEqual(p.reach, .wide)
        XCTAssertEqual(lastQuery, .weather)
    }
}
