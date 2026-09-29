import XCTest
@testable import AXTerm

/// The directed-query catalogue and the query an operator builds from it.
final class APRSDirectedQueryTests: XCTestCase {

    /// The distinction the whole Ask sheet is built around, pinned so a new
    /// query cannot be added without deciding which kind it is. A query
    /// answered with a broadcast can never be *proved* to have been answered;
    /// one answered with a message always can.
    func testProvableQueriesAreTheOnesAnsweredWithAMessage() {
        XCTAssertTrue(APRSDirectedQuery.version.isProvable)
        XCTAssertTrue(APRSDirectedQuery.trace.isProvable)
        XCTAssertTrue(APRSDirectedQuery.directs.isProvable)
        XCTAssertFalse(APRSDirectedQuery.position.isProvable, "a position report is a broadcast")
        XCTAssertFalse(APRSDirectedQuery.status.isProvable)
        XCTAssertFalse(APRSDirectedQuery.objects.isProvable)
    }

    /// Every query carries the token it transmits, and no two share one.
    func testTokensAreDistinctAndWellFormed() {
        let tokens = APRSDirectedQuery.allCases.map(\.token)
        XCTAssertEqual(Set(tokens).count, tokens.count)
        for token in tokens {
            XCTAssertTrue(token.hasPrefix("?"), token)
            XCTAssertEqual(token, token.uppercased(), token)
        }
    }

    /// The badge claiming AXTerm answers a query has to match what
    /// `APRSMessagingService.receiveQuery` actually answers, or the app is
    /// advertising something it does not do.
    func testTheAnsweredSetMatchesWhatWeImplement() {
        XCTAssertEqual(Set(APRSDirectedQuery.allCases.filter(\.axtermAnswersIt)),
                       [.position, .trace, .version, .directs])
    }

    // MARK: - Building one

    func testAPickedQueryCarriesItsToken() {
        let ask = APRSStationQuery(callsign: "ad1ct", kind: .version, reach: .wide)
        XCTAssertEqual(ask.callsign, "AD1CT")
        XCTAssertEqual(ask.token, "?VER")
        XCTAssertEqual(ask.reach, .wide)
        XCTAssertTrue(ask.isValid)
    }

    /// The spec writes query tokens uppercase with a leading `?`, and a
    /// station that follows it — Xastir does — refuses any other case as an
    /// illegal query rather than guessing. A typed query is normalised so a
    /// lowercase one does not silently go nowhere.
    func testATypedQueryIsNormalisedTheWayTheSpecWritesThem() {
        XCTAssertEqual(APRSStationQuery(callsign: "AD1CT", custom: "aprsh k0epi").token,
                       "?APRSH K0EPI")
        XCTAssertEqual(APRSStationQuery(callsign: "AD1CT", custom: "  ?ver  ").token, "?VER")
    }

    /// A typed query that happens to be one of ours is recognised, so the
    /// result reads with the same wording as the picked one.
    func testATypedQueryThatMatchesTheCatalogueIsIdentified() {
        XCTAssertEqual(APRSStationQuery(callsign: "AD1CT", custom: "?aprst").kind, .trace)
        XCTAssertNil(APRSStationQuery(callsign: "AD1CT", custom: "?igate?").kind)
    }

    /// Nothing empty and nothing longer than a message body goes on the air.
    func testAnEmptyOrOversizedQueryIsRefused() {
        XCTAssertFalse(APRSStationQuery(callsign: "AD1CT", custom: "").isValid)
        XCTAssertFalse(APRSStationQuery(callsign: "AD1CT", custom: "?").isValid)
        XCTAssertFalse(APRSStationQuery(callsign: "", kind: .position).isValid)
        let long = String(repeating: "X", count: APRSMessage.maxTextLength + 1)
        XCTAssertFalse(APRSStationQuery(callsign: "AD1CT", custom: long).isValid)
    }
}
