import XCTest
@testable import AXTerm

/// Objects and items — the incident-reporting payload. The lifecycle rules
/// here are safety rules, not tidiness: a hazard that will not clear, or one
/// anybody can silence, is worse than no hazard layer at all.
final class APRSObjectTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func parse(_ info: String) -> APRSObjectReport? {
        APRSObjectReport.parse(info: Data(info.utf8))
    }

    // MARK: - Objects

    func testLiveObjectWithUncompressedPosition() throws {
        let report = try XCTUnwrap(parse(";BRIDGE   *092345z3959.13N/10515.42W!Bridge out, impassable"))
        XCTAssertEqual(report.kind, .object)
        XCTAssertEqual(report.name, "BRIDGE", "the nine-character padding is trimmed")
        XCTAssertTrue(report.isLive)
        XCTAssertEqual(report.latitude, 39.9855, accuracy: 0.001)
        XCTAssertEqual(report.longitude, -105.257, accuracy: 0.001)
        XCTAssertEqual(report.symbolCode, "!")
        XCTAssertEqual(report.comment, "Bridge out, impassable")
    }

    func testKilledObjectIsParsedAsKilledNotDiscarded() throws {
        let report = try XCTUnwrap(parse(";BRIDGE   _092345z3959.13N/10515.42W!"))
        XCTAssertFalse(report.isLive, "the sender is standing it down, which is information")
    }

    /// The state byte must be `*` or `_`. Anything else means this is not an
    /// object report and guessing would place a point from a random packet.
    func testAnObjectWithoutAValidStateByteIsRejected() {
        XCTAssertNil(parse(";BRIDGE   X092345z3959.13N/10515.42W!"))
    }

    func testAnObjectWithoutAValidTimestampIsRejected() {
        XCTAssertNil(parse(";BRIDGE   *NOTATIME3959.13N/10515.42W!"))
    }

    func testObjectCarryingWeatherIsDecoded() throws {
        let report = try XCTUnwrap(
            parse(";REMOTEWX *092345z3959.13N/10515.42W_220/004g009t047h63"))
        XCTAssertEqual(report.weather?.temperatureF, 47)
        XCTAssertEqual(report.weather?.humidityPercent, 63)
    }

    // MARK: - Items

    func testLiveItem() throws {
        let report = try XCTUnwrap(parse(")AIDSTN!3959.13N/10515.42WAWater and first aid"))
        XCTAssertEqual(report.kind, .item)
        XCTAssertEqual(report.name, "AIDSTN")
        XCTAssertTrue(report.isLive)
        XCTAssertEqual(report.symbolCode, "A")
        XCTAssertEqual(report.comment, "Water and first aid")
    }

    func testKilledItem() throws {
        let report = try XCTUnwrap(parse(")AIDSTN_3959.13N/10515.42WA"))
        XCTAssertFalse(report.isLive)
    }

    func testNonObjectPayloadsAreIgnored() {
        XCTAssertNil(parse("!3959.13N/10515.42W#a plain position"))
        XCTAssertNil(parse(">status text"))
        XCTAssertNil(parse(""))
    }

    // MARK: - Urgency

    /// Only a small set of symbols means "something is wrong". A list that
    /// flags everything flags nothing.
    func testUrgencyComesFromTheSymbol() throws {
        let fire = try XCTUnwrap(parse(";WILDFIRE *092345z3959.13N/10515.42W:East ridge"))
        XCTAssertEqual(fire.urgency, .hazard)

        let shelter = try XCTUnwrap(parse(")SHELTER!3959.13N/10515.42W+Red Cross"))
        XCTAssertEqual(shelter.urgency, .notable)

        let marker = try XCTUnwrap(parse(")MEETPT!3959.13N/10515.42W-"))
        XCTAssertEqual(marker.urgency, .marker)
    }

    /// **The symbol table matters.** `/!` is a police station — somewhere to
    /// go — and `\!` is Emergency. Classifying by the code alone raised a
    /// hazard banner for every sheriff's office, which is exactly how an
    /// operator learns to ignore the banner.
    func testPoliceStationIsNotAHazardButEmergencyIs() throws {
        let police = try XCTUnwrap(parse(";SHERIFF  *092345z3959.13N/10515.42W!County office"))
        XCTAssertEqual(police.urgency, .notable)
        XCTAssertEqual(police.symbolTable, "/")

        let emergency = try XCTUnwrap(
            parse(";MAYDAY   *092345z3959.13N\\10515.42W!Person trapped"))
        XCTAssertEqual(emergency.symbolTable, "\\")
        XCTAssertEqual(emergency.urgency, .hazard)
    }

    /// An overlay puts a digit or letter where the table character goes; it is
    /// still an alternate-table symbol and must classify as one.
    func testAnOverlaySymbolClassifiesAsAlternateTable() throws {
        let overlaid = try XCTUnwrap(
            parse(";SMOKE    *092345z3959.13N010515.42We"))
        XCTAssertEqual(overlaid.urgency, .hazard, "overlaid smoke is still smoke")
    }

    // MARK: - The store

    func testRecordingAndRepeatingAnObject() {
        var store = APRSObjectStore()
        let report = parse(";WILDFIRE *092345z3959.13N/10515.42W:East ridge")!

        XCTAssertTrue(store.record(report, from: "K0EPI-7", at: now))
        XCTAssertEqual(store.live(now: now).count, 1)
        XCTAssertEqual(store.live(now: now).first?.timesHeard, 1)
        XCTAssertEqual(store.live(now: now).first?.reportedBy, "K0EPI-7")

        // A repeat of the identical object is not a change worth redrawing
        // for, but it does prove the reporter is still maintaining it.
        XCTAssertFalse(store.record(report, from: "K0EPI-7", at: now.addingTimeInterval(600)))
        XCTAssertEqual(store.live(now: now).first?.timesHeard, 2)
    }

    /// **A safety rule.** Only the station that placed an object may retire
    /// it. Otherwise anybody on the channel can silence anybody else's hazard
    /// report by transmitting a kill for its name.
    func testOnlyTheOwnerCanKillAnObject() {
        var store = APRSObjectStore()
        store.record(parse(";WILDFIRE *092345z3959.13N/10515.42W:East ridge")!,
                     from: "K0EPI-7", at: now)

        let kill = parse(";WILDFIRE _092345z3959.13N/10515.42W:")!
        XCTAssertFalse(store.record(kill, from: "N0BODY-1", at: now.addingTimeInterval(60)),
                       "a stranger's kill must be ignored")
        XCTAssertEqual(store.live(now: now).count, 1, "the hazard is still up")

        XCTAssertTrue(store.record(kill, from: "K0EPI-7", at: now.addingTimeInterval(120)))
        XCTAssertTrue(store.live(now: now).isEmpty, "its owner stood it down")
    }

    /// Object names are compared case-insensitively after trimming, so a
    /// station can kill what it created even if the padding differs.
    func testNamesMatchAcrossPaddingAndCase() {
        var store = APRSObjectStore()
        store.record(parse(";Fire     *092345z3959.13N/10515.42W:")!, from: "K0EPI-7", at: now)
        let kill = parse(";FIRE     _092345z3959.13N/10515.42W:")!
        XCTAssertTrue(store.record(kill, from: "K0EPI-7", at: now.addingTimeInterval(60)))
        XCTAssertTrue(store.live(now: now).isEmpty)
    }

    /// Objects are meant to be re-beaconed while they are true, so silence is
    /// information. One nobody has repeated for six hours stops being drawn as
    /// current — but it is kept, so it can be said to have gone quiet rather
    /// than simply vanishing.
    func testAnUnrepeatedObjectStopsBeingLiveButIsNotLost() {
        var store = APRSObjectStore()
        store.record(parse(";WILDFIRE *092345z3959.13N/10515.42W:")!, from: "K0EPI-7", at: now)

        let later = now.addingTimeInterval(APRSObjectStore.liveWindow + 60)
        XCTAssertTrue(store.live(now: later).isEmpty)
        XCTAssertEqual(store.expired(now: later).count, 1)
    }

    func testHazardsAreListedFirstAndSeparately() {
        var store = APRSObjectStore()
        store.record(parse(")MEETPT!3959.13N/10515.42W-")!, from: "K0EPI-7", at: now)
        store.record(parse(";WILDFIRE *092345z3959.13N/10515.42W:")!,
                     from: "W0AAA-1", at: now.addingTimeInterval(-60))

        XCTAssertEqual(store.hazards(now: now).count, 1)
        XCTAssertEqual(store.live(now: now).first?.report.name, "WILDFIRE",
                       "a hazard outranks a newer marker")
    }

    /// A live report re-raises something its owner had killed: conditions
    /// change back, and the map has to be able to say so.
    func testAKilledObjectCanBeRaisedAgain() {
        var store = APRSObjectStore()
        let live = parse(";ROADCLSD *092345z3959.13N/10515.42W!")!
        let kill = parse(";ROADCLSD _092345z3959.13N/10515.42W!")!
        store.record(live, from: "K0EPI-7", at: now)
        store.record(kill, from: "K0EPI-7", at: now.addingTimeInterval(60))
        XCTAssertTrue(store.live(now: now).isEmpty)

        store.record(live, from: "K0EPI-7", at: now.addingTimeInterval(120))
        XCTAssertEqual(store.live(now: now).count, 1)
    }

    /// A kill for something never heard must not create a tombstone for an
    /// object this receiver has no record of.
    func testAKillForAnUnknownObjectIsIgnored() {
        var store = APRSObjectStore()
        let kill = parse(";NEVERSEEN_092345z3959.13N/10515.42W!")!
        XCTAssertFalse(store.record(kill, from: "K0EPI-7", at: now))
        XCTAssertTrue(store.live(now: now).isEmpty)
    }

    // MARK: - What the card says

    /// Attribution comes first. An object is a claim by a person, and who made
    /// it is the first thing that decides how much weight it carries.
    func testTheCardNamesTheReporterAndTheAge() {
        var store = APRSObjectStore()
        store.record(parse(";WILDFIRE *092345z3959.13N/10515.42W:East ridge")!,
                     from: "W0AAA-1", at: now)
        let placed = store.live(now: now)[0]
        let text = StationsMapView.objectDetail(
            placed, observer: GreatCircle.Point(latitude: 39.7, longitude: -104.9),
            now: now, inMiles: true)

        XCTAssertTrue(text.contains("WILDFIRE"))
        XCTAssertTrue(text.contains("East ridge"))
        XCTAssertTrue(text.contains("Reported by W0AAA-1"))
        XCTAssertTrue(text.contains("unconfirmed"), "heard once and not repeated")
    }

    func testARepeatedObjectIsNotMarkedUnconfirmed() {
        var store = APRSObjectStore()
        let report = parse(";WILDFIRE *092345z3959.13N/10515.42W:East ridge")!
        store.record(report, from: "W0AAA-1", at: now)
        store.record(report, from: "W0AAA-1", at: now.addingTimeInterval(600))
        let text = StationsMapView.objectDetail(
            store.live(now: now)[0],
            observer: GreatCircle.Point(latitude: 39.7, longitude: -104.9),
            now: now, inMiles: true)
        XCTAssertFalse(text.contains("unconfirmed"))
        XCTAssertTrue(text.contains("repeated 2 times"))
    }

    /// An object named after a callsign must not collide with the station of
    /// that name on the map.
    func testObjectSiteIDsCannotCollideWithStations() {
        XCTAssertNotEqual(StationsMapView.objectSiteID("K0EPI-7"), "K0EPI-7")
    }
}
