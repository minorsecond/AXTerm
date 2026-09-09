import XCTest
@testable import AXTerm

/// The frames AXTerm puts on the air when an operator marks something.
///
/// Objects are how an incident net actually works — road closures, aid
/// stations, fire perimeters — and until now AXTerm could only read them.
/// An encoder is where a protocol goes wrong quietly: a name one character
/// short still parses somewhere and lands in the wrong field everywhere else.
final class APRSObjectComposeTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_757_419_200)   // 09 Sep 2026 12:00 UTC

    // MARK: - The wire format

    /// Nine characters, always. Every implementation finds the state byte at
    /// a fixed offset, so a name of the wrong length silently corrupts the
    /// timestamp and the position for every receiver but us.
    func testTheNameIsExactlyNineCharactersOnTheWire() {
        XCTAssertEqual(APRSObjectReport.wireName("FIRE").count, 9)
        XCTAssertEqual(APRSObjectReport.wireName("").count, 9)
        XCTAssertEqual(APRSObjectReport.wireName("ROADCLOSURE-NORTH").count, 9)
        XCTAssertEqual(APRSObjectReport.wireName("AID"), "AID      ")
    }

    /// A name is truncated rather than refused: the alternative is an operator
    /// marking a closure in an emergency and being argued with by a text field.
    func testALongNameIsTruncatedNotRefused() {
        XCTAssertEqual(APRSObjectReport.wireName("EVACUATION ROUTE"), "EVACUATIO")
        XCTAssertTrue(APRSObjectReport.isTransmittableName("EVACUATION ROUTE"))
    }

    /// `!` and `_` terminate an item name and `;`/`)` start a report. A typed
    /// name containing them would not survive its own round trip.
    func testCharactersThatWouldBreakTheFrameAreStripped() {
        XCTAssertEqual(APRSObjectReport.wireName("FIRE!"), "FIRE     ")
        XCTAssertEqual(APRSObjectReport.wireName("A_B;C)D"), "ABCD     ")
        XCTAssertFalse(APRSObjectReport.isTransmittableName("!!!"),
                       "nothing left after stripping is not a name")
        XCTAssertFalse(APRSObjectReport.isTransmittableName("   "))
    }

    func testTheTimestampIsUTCInTheFormatTheSpecAsks() {
        let info = APRSObjectReport.objectInfo(
            name: "AID", live: true, latitude: 39.6117, longitude: -104.7317,
            symbolTable: "/", symbolCode: "+", at: noon)
        XCTAssertTrue(info.hasPrefix(";AID      *091200z"), info)
    }

    // MARK: - Against a frame we did not write

    /// Our parser agreeing with our encoder is one implementation agreeing
    /// with itself. This pins the field geometry against a real object
    /// captured off K0EPI-7's channel — METHOD's repeater marker, generated
    /// by a WX3in1 and independently decoded by Direwolf (see
    /// `Fixtures/aprs-zoo.json`). Every offset below is one that another
    /// implementation reads at a fixed position.
    func testTheFieldGeometryMatchesARealOffAirObject() {
        let real = ";147.285CO*111111z3826.78N/10600.65WrT88 R40m repeater"
        let ours = APRSObjectReport.objectInfo(
            name: "AID", live: true, latitude: 39.6117, longitude: -104.7317,
            symbolTable: "/", symbolCode: "+", comment: "water", at: noon)

        func field(_ s: String, _ lower: Int, _ upper: Int) -> String {
            let chars = Array(s)
            return String(chars[lower..<min(upper, chars.count)])
        }
        XCTAssertEqual(field(ours, 0, 1), field(real, 0, 1), "data type identifier")
        XCTAssertEqual(field(ours, 1, 10).count, field(real, 1, 10).count, "9-character name")
        XCTAssertEqual(field(ours, 10, 11), field(real, 10, 11), "live marker")
        XCTAssertEqual(field(ours, 11, 18).count, field(real, 11, 18).count, "7-character stamp")
        XCTAssertEqual(field(ours, 17, 18), field(real, 17, 18), "timestamp unit")
        // The position field: 8 lat + table + 9 lon + code = 19 characters.
        XCTAssertEqual(field(ours, 18, 37).count, field(real, 18, 37).count)
        XCTAssertEqual(field(ours, 26, 27), "/", "symbol table sits between lat and lon")
        XCTAssertEqual(field(real, 26, 27), "/")
    }

    // MARK: - Round trip through our own parser

    func testAPlacedObjectParsesBackToWhatWasPlaced() throws {
        let info = APRSObjectReport.objectInfo(
            name: "ROADCLOSE", live: true, latitude: 39.6117, longitude: -104.7317,
            symbolTable: "/", symbolCode: "-", comment: "US-85 washed out", at: noon)
        let back = try XCTUnwrap(APRSObjectReport.parse(info: Data(info.utf8)))
        XCTAssertEqual(back.kind, .object)
        XCTAssertEqual(back.name, "ROADCLOSE")
        XCTAssertTrue(back.isLive)
        XCTAssertEqual(back.latitude, 39.6117, accuracy: 0.001)
        XCTAssertEqual(back.longitude, -104.7317, accuracy: 0.001)
        XCTAssertEqual(back.symbolTable, "/")
        XCTAssertEqual(back.symbolCode, "-")
        XCTAssertEqual(back.comment, "US-85 washed out")
    }

    /// The kill must key to the same object, or it removes nothing and the
    /// incident stays on every map on the channel.
    func testAKillMatchesTheObjectItRemoves() throws {
        let placed = try XCTUnwrap(APRSObjectReport.parse(info: Data(
            APRSObjectReport.objectInfo(
                name: "Fire", live: true, latitude: 39.6, longitude: -104.7,
                symbolTable: "\\", symbolCode: "w", at: noon).utf8)))
        let killed = try XCTUnwrap(APRSObjectReport.parse(info: Data(
            APRSObjectReport.killInfo(
                name: "Fire", latitude: 39.6, longitude: -104.7,
                symbolTable: "\\", symbolCode: "w", at: noon).utf8)))
        XCTAssertTrue(placed.isLive)
        XCTAssertFalse(killed.isLive)
        XCTAssertEqual(placed.key, killed.key, "same object, or the kill does nothing")
    }

    /// A name that only differs by case or padding is the same object, so a
    /// kill typed differently from the placement still works.
    func testAKillTypedDifferentlyStillMatches() throws {
        let placed = try XCTUnwrap(APRSObjectReport.parse(info: Data(
            APRSObjectReport.objectInfo(name: "aid", live: true, latitude: 39.6,
                                        longitude: -104.7, symbolTable: "/",
                                        symbolCode: "+", at: noon).utf8)))
        let killed = try XCTUnwrap(APRSObjectReport.parse(info: Data(
            APRSObjectReport.killInfo(name: "  AID ", latitude: 39.6, longitude: -104.7,
                                      symbolTable: "/", symbolCode: "+", at: noon).utf8)))
        XCTAssertEqual(placed.key, killed.key)
    }

    /// A newline in a comment would end the information field early and
    /// truncate the frame.
    func testANewlineInACommentCannotTruncateTheFrame() throws {
        let info = APRSObjectReport.objectInfo(
            name: "AID", live: true, latitude: 39.6, longitude: -104.7,
            symbolTable: "/", symbolCode: "+", comment: "water\nand shade", at: noon)
        XCTAssertFalse(info.contains("\n"), info)
        let back = try XCTUnwrap(APRSObjectReport.parse(info: Data(info.utf8)))
        XCTAssertEqual(back.comment, "water and shade")
    }
}

/// Re-announcing an object we already own.
///
/// Used to answer `?APRSO`, and by "move" — both need the same thing, which is
/// the report as it would go out *now* rather than a replay of the frame it
/// arrived in.
final class APRSObjectReannounceTests: XCTestCase {

    private let placed = Date(timeIntervalSince1970: 1_757_419_200)   // 091200z

    private func report(_ info: String) throws -> APRSObjectReport {
        try XCTUnwrap(APRSObjectReport.parse(info: Data(info.utf8)))
    }

    /// The whole point of rebuilding rather than replaying: a replayed frame is
    /// byte-identical, and an object timestamp is what a receiver reads to
    /// weigh a six-hour-old hazard against a current one.
    func testReannouncingCarriesTheCurrentTimeNotTheOriginal() throws {
        let original = APRSObjectReport.objectInfo(
            name: "ROADCLOSE", live: true, latitude: 39.6117, longitude: -104.7317,
            symbolTable: "\\", symbolCode: "x", comment: "US-85 washed out", at: placed)
        let again = try XCTUnwrap(report(original).reannounced(at: placed.addingTimeInterval(3600)))
        XCTAssertNotEqual(again, original, "a replay would be dropped as a duplicate")
        XCTAssertTrue(again.contains("091300z"), again)
        // Everything a receiver acts on survives the round trip.
        let back = try report(again)
        XCTAssertEqual(back.name, "ROADCLOSE")
        XCTAssertEqual(back.symbolTable, "\\")
        XCTAssertEqual(back.symbolCode, "x")
        XCTAssertEqual(back.comment, "US-85 washed out")
        XCTAssertTrue(back.isLive)
    }

    /// A killed object is not re-announced. Answering `?APRSO` with something
    /// we stood down would resurrect it on every receiver in range.
    func testAKilledObjectIsNotReannounced() throws {
        let killed = APRSObjectReport.killInfo(
            name: "ROADCLOSE", latitude: 39.6117, longitude: -104.7317,
            symbolTable: "/", symbolCode: "-", at: placed)
        XCTAssertNil(try report(killed).reannounced(at: placed))
    }

    /// Items carry no timestamp and this station never transmits one, so an
    /// item under our callsign is somebody else's and not ours to repeat.
    func testAnItemIsNotReannounced() throws {
        let item = try report(")AIDSTN!3936.70N/10443.90W-water")
        XCTAssertEqual(item.kind, .item)
        XCTAssertNil(item.reannounced(at: placed))
    }
}
