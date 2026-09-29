import XCTest
@testable import AXTerm

/// What makes the map redraw at once instead of waiting for the throttle.
///
/// The annotation throttle is ten seconds and exists to absorb packet-rate
/// churn. It must not absorb the operator's own action: placing an object and
/// watching nothing happen reads as a broken button, which is the same failure
/// the layer switches already had.
final class MapOwnObjectTokenTests: XCTestCase {

    private let t = Date(timeIntervalSince1970: 1_757_419_200)

    private func placed(_ name: String, by station: String,
                        lat: Double = 39.6, lon: Double = -104.7,
                        table: Character = "/", code: Character = "-")
    throws -> APRSObjectStore.Placed {
        var store = APRSObjectStore()
        let info = APRSObjectReport.objectInfo(
            name: name, live: true, latitude: lat, longitude: lon,
            symbolTable: table, symbolCode: code, at: t)
        store.record(try XCTUnwrap(APRSObjectReport.parse(info: Data(info.utf8))),
                     from: station, at: t)
        return try XCTUnwrap(store.live(now: t).first)
    }

    private func token(_ objects: [APRSObjectStore.Placed]) -> String {
        MapLayerGeneration.ownObjectToken(objects, ours: ["K0EPI-7"])
    }

    /// Placing changes the signature, so the marker lands on the pass that
    /// follows the transmission rather than up to ten seconds later.
    func testPlacingOurOwnObjectChangesTheToken() throws {
        XCTAssertNotEqual(token([]), token([try placed("ROADCLOSE", by: "K0EPI-7")]))
    }

    /// Moving it changes the signature too. Only the position differs, so a
    /// token built from names alone would have made a move wait.
    func testMovingItChangesTheToken() throws {
        let before = try placed("ROADCLOSE", by: "K0EPI-7", lat: 39.6, lon: -104.7)
        let after = try placed("ROADCLOSE", by: "K0EPI-7", lat: 39.7, lon: -104.8)
        XCTAssertNotEqual(token([before]), token([after]))
    }

    /// And correcting the symbol, which is the other thing a move sheet can
    /// change without touching the name.
    func testCorrectingTheSymbolChangesTheToken() throws {
        let before = try placed("FIRE", by: "K0EPI-7", table: "/", code: ":")
        let after = try placed("FIRE", by: "K0EPI-7", table: "\\", code: "x")
        XCTAssertNotEqual(token([before]), token([after]))
    }

    /// Standing it down changes it back — the marker has to leave as promptly
    /// as it arrived, or the operator stands something down and watches it sit
    /// there.
    func testStandingItDownChangesTheToken() throws {
        XCTAssertEqual(token([]), token([]))
        XCTAssertNotEqual(token([try placed("ROADCLOSE", by: "K0EPI-7")]), token([]))
    }

    /// The whole point of filtering by owner: a stranger's object *is*
    /// packet-rate churn. If it bypassed the throttle, a busy incident net
    /// would defeat the throttle continuously — which is the load it exists
    /// to prevent.
    func testSomebodyElsesObjectDoesNotChangeTheToken() throws {
        XCTAssertEqual(token([try placed("THEIRS", by: "W0ARP-10")]), token([]))
    }

    /// Sorted, so dictionary order in the store cannot make an unchanged map
    /// look changed on every pass and defeat the throttle by accident.
    func testTheTokenDoesNotDependOnOrder() throws {
        let a = try placed("AAA", by: "K0EPI-7", lat: 39.1, lon: -104.1)
        let b = try placed("BBB", by: "K0EPI-7", lat: 39.2, lon: -104.2)
        XCTAssertEqual(token([a, b]), token([b, a]))
    }

    /// Ownership is compared the way the rest of APRS compares callsigns.
    func testOwnershipIsCaseInsensitive() throws {
        XCTAssertNotEqual(
            MapLayerGeneration.ownObjectToken([try placed("X", by: "k0epi-7")],
                                              ours: ["K0EPI-7"]),
            "")
    }
}
