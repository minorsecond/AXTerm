import XCTest
@testable import AXTerm

/// Space weather, and what it is honestly allowed to explain.
///
/// The temptation with solar indices is to print them beside a poor session
/// and let the operator draw the obvious conclusion. For this station that
/// conclusion would usually be wrong: every RF session in the log is on
/// 145.050 MHz, and solar flux has almost nothing to do with a 1200-baud
/// link to a gateway down the road. Blaming the sun for a bad 2 m session
/// hides the causes that actually apply — noise, collisions, terrain, a
/// stuck carrier — and sends the operator looking at the wrong thing.
///
/// So the indices are recorded for every day a session runs, and what they
/// are permitted to claim depends on the band.
final class SolarConditionsTests: XCTestCase {

    // MARK: - What solar conditions bear on

    /// On HF the ionosphere *is* the path. Nothing else comes close.
    func testOnHFPropagationIsTheStory() {
        XCTAssertEqual(SolarBandRelevance.relevance(frequencyHz: 7_100_000, transport: "ax25"), .dominant)
        XCTAssertEqual(SolarBandRelevance.relevance(frequencyHz: 14_105_000, transport: "ax25"), .dominant)
        XCTAssertEqual(SolarBandRelevance.relevance(frequencyHz: 28_120_000, transport: "ax25"), .dominant)
    }

    /// Six metres opens and closes on sporadic-E and aurora, so the indices
    /// genuinely matter — just not every day.
    func testSixMetresIsGenuinelyAffected() {
        XCTAssertEqual(SolarBandRelevance.relevance(frequencyHz: 50_313_000, transport: "ax25"), .significant)
    }

    /// Two metres is the case that matters here, and the honest answer is
    /// "hardly ever" — a disturbed field can bring auroral effects, but a
    /// local packet link is dominated by things on the ground.
    func testTwoMetresIsMarginal() {
        XCTAssertEqual(SolarBandRelevance.relevance(frequencyHz: 145_050_000, transport: "ax25"), .marginal)
        XCTAssertEqual(SolarBandRelevance.relevance(frequencyHz: 144_390_000, transport: "ax25"), .marginal)
    }

    func testSeventyCentimetresIsNegligible() {
        XCTAssertEqual(SolarBandRelevance.relevance(frequencyHz: 441_075_000, transport: "ax25"), .negligible)
    }

    /// A telnet session went over the internet. There is no radio path for
    /// space weather to affect at all, and that is knowable from the
    /// transport rather than inferred.
    func testAPathWithNoRadioInItIsUnaffected() {
        XCTAssertEqual(
            SolarBandRelevance.relevance(frequencyHz: nil, transport: "telnet"), .noRadioPath)
    }

    /// The correction that matters: an RF session with no frequency recorded
    /// was still on the air. Fifteen of this station's own ax25 sessions have
    /// a null frequency, and reading that as "no radio" would quietly dismiss
    /// space weather for sessions it may well have affected. Unknown is its
    /// own answer — no band is assumed in either direction.
    func testAnUnknownFrequencyIsNotTreatedAsNoRadio() {
        let relevance = SolarBandRelevance.relevance(frequencyHz: nil, transport: "ax25")
        XCTAssertEqual(relevance, .unknownBand)
        XCTAssertNotEqual(relevance, .noRadioPath)
        XCTAssertNotEqual(relevance, .negligible)
    }

    /// And it says so, rather than making a claim it has no basis for.
    func testAnUnknownBandDeclinesToJudge() throws {
        let note = try XCTUnwrap(SolarBandRelevance.note(
            frequencyHz: nil, transport: "ax25", kIndex: 5))
        XCTAssertTrue(note.lowercased().contains("not recorded")
                      || note.lowercased().contains("unknown"), note)
    }

    // MARK: - What we tell the operator

    /// The note for VHF must actively point away from the sun, or printing
    /// the indices there does harm.
    func testTheTwoMetreNoteSendsYouToTheRealCauses() throws {
        let note = try XCTUnwrap(SolarBandRelevance.note(frequencyHz: 145_050_000, transport: "ax25", kIndex: 2))
        let lower = note.lowercased()
        XCTAssertTrue(lower.contains("little"), note)
        XCTAssertTrue(lower.contains("noise") || lower.contains("local"), note)
    }

    /// A genuinely disturbed field is the one time 2 m can be affected, and
    /// the note should change rather than repeating the same disclaimer.
    func testAStormyFieldChangesTheTwoMetreNote() throws {
        let calm = try XCTUnwrap(SolarBandRelevance.note(frequencyHz: 145_050_000, transport: "ax25", kIndex: 1))
        let storm = try XCTUnwrap(SolarBandRelevance.note(frequencyHz: 145_050_000, transport: "ax25", kIndex: 7))
        XCTAssertNotEqual(calm, storm)
        XCTAssertTrue(storm.lowercased().contains("aurora"), storm)
    }

    /// On HF there is nothing to disclaim.
    func testHFNeedsNoDisclaimer() {
        XCTAssertNil(SolarBandRelevance.note(frequencyHz: 14_105_000, transport: "ax25", kIndex: 4))
    }

    // MARK: - Reading the indices

    /// Kp is the number an operator recognises, so the wording is the
    /// standard one rather than an invention.
    func testKIndexIsDescribedInTheUsualTerms() {
        XCTAssertEqual(SolarConditions.geomagneticDescription(kIndex: 0), "quiet")
        XCTAssertEqual(SolarConditions.geomagneticDescription(kIndex: 3), "unsettled")
        XCTAssertEqual(SolarConditions.geomagneticDescription(kIndex: 4), "active")
        XCTAssertEqual(SolarConditions.geomagneticDescription(kIndex: 5), "minor storm")
        XCTAssertEqual(SolarConditions.geomagneticDescription(kIndex: 8), "severe storm")
    }

    func testAnUnknownIndexDescribesNothing() {
        XCTAssertNil(SolarConditions.geomagneticDescription(kIndex: nil))
    }

    // MARK: - Parsing NOAA's answers

    /// SWPC's flux feed, in its published shape.
    func testParsesTheSolarFluxFeed() throws {
        let json = """
        [{"time_tag":"2026-08-30T00:00:00","flux":168.2},
         {"time_tag":"2026-08-31T00:00:00","flux":171.5}]
        """
        let points = try SolarConditionsFeed.parseFlux(Data(json.utf8))
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.last?.flux ?? 0, 171.5, accuracy: 0.01)
    }

    /// The planetary K product is a header row followed by arrays, which is
    /// a different shape from the flux feed and has to be read as one.
    func testParsesThePlanetaryKProduct() throws {
        let json = """
        [["time_tag","Kp","a_running","station_count"],
         ["2026-08-31 00:00:00","2.33","5","8"],
         ["2026-08-31 03:00:00","4.67","12","8"]]
        """
        let points = try SolarConditionsFeed.parsePlanetaryK(Data(json.utf8))
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.last?.kIndex ?? 0, 4.67, accuracy: 0.01)
    }

    /// A feed that changed shape must fail loudly rather than yielding
    /// plausible zeros — a fabricated calm field is worse than no reading.
    func testAMalformedFeedIsRejectedRatherThanGuessed() {
        XCTAssertThrowsError(try SolarConditionsFeed.parseFlux(Data("{\"nope\":true}".utf8)))
        XCTAssertThrowsError(try SolarConditionsFeed.parsePlanetaryK(Data("[]".utf8)))
    }
}
