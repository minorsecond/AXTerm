import XCTest
@testable import AXTerm

final class APRSStationClassTests: XCTestCase {

    func testInfrastructureCodes() {
        XCTAssertEqual(APRSStationClass.classify(code: "#", hasMotion: false), .infrastructure)
        XCTAssertEqual(APRSStationClass.classify(code: "&", hasMotion: false), .infrastructure)
        XCTAssertEqual(APRSStationClass.classify(code: "I", hasMotion: false), .infrastructure)
        XCTAssertEqual(APRSStationClass.classify(code: "r", hasMotion: false), .infrastructure)
    }

    func testVehicleSymbolsAreMoving() {
        XCTAssertEqual(APRSStationClass.classify(code: ">", hasMotion: false), .moving)   // car
        XCTAssertEqual(APRSStationClass.classify(code: "j", hasMotion: false), .moving)   // jeep
        XCTAssertEqual(APRSStationClass.classify(code: "'", hasMotion: false), .moving)   // aircraft
    }

    func testMotionWinsOverAFixedSymbol() {
        // A home symbol that is reporting course/speed is a mover.
        XCTAssertEqual(APRSStationClass.classify(code: "-", hasMotion: true), .moving)
    }

    func testFixedNonInfrastructure() {
        XCTAssertEqual(APRSStationClass.classify(code: "-", hasMotion: false), .fixed)    // house
        XCTAssertEqual(APRSStationClass.classify(code: "_", hasMotion: false), .fixed)    // weather
    }

    func testScopeMembership() {
        XCTAssertTrue(APRSProbeScope.all.includes(.fixed))
        XCTAssertTrue(APRSProbeScope.all.includes(.infrastructure))
        XCTAssertTrue(APRSProbeScope.infrastructure.includes(.infrastructure))
        XCTAssertFalse(APRSProbeScope.infrastructure.includes(.moving))
        XCTAssertTrue(APRSProbeScope.moving.includes(.moving))
        XCTAssertFalse(APRSProbeScope.moving.includes(.fixed))
    }

    // MARK: - Human type label for the selection card

    func testTheLabelNamesTheInfrastructureSpecifically() {
        XCTAssertEqual(APRSSymbolType.label(code: "#"), "Digipeater")
        XCTAssertEqual(APRSSymbolType.label(code: "&"), "Gateway (i-gate)")
        XCTAssertEqual(APRSSymbolType.label(code: "I"), "I-gate")
        XCTAssertEqual(APRSSymbolType.label(code: "r"), "Repeater")
    }

    func testWeatherIsNamedEvenThoughItClassifiesFixed() {
        XCTAssertEqual(APRSStationClass.classify(code: "_", hasMotion: false), .fixed)
        XCTAssertEqual(APRSSymbolType.label(code: "_"), "Weather station")
    }

    func testHomeVersusOtherFixed() {
        XCTAssertEqual(APRSSymbolType.label(code: "-"), "Home station")
        XCTAssertEqual(APRSSymbolType.label(code: "/"), "Fixed station")
    }

    func testEveryVehicleReadsAsOneHonestWord() {
        // The vehicle set spans cars, boats, aircraft; none is mislabelled.
        for code in [">", "<", "s", "Y", "^", "g"] {
            XCTAssertEqual(APRSSymbolType.label(code: Character(code)), "Vehicle", code)
        }
    }


    // MARK: - The four map buckets (colour / filter / legend agree)

    func testTypeBucketMapping() {
        XCTAssertEqual(APRSTypeBucket.of(code: "#"), .digipeater)
        XCTAssertEqual(APRSTypeBucket.of(code: "&"), .digipeater)
        XCTAssertEqual(APRSTypeBucket.of(code: "I"), .digipeater)
        XCTAssertEqual(APRSTypeBucket.of(code: "r"), .digipeater)
        XCTAssertEqual(APRSTypeBucket.of(code: "_"), .weather)
        XCTAssertEqual(APRSTypeBucket.of(code: ">"), .vehicle)
        XCTAssertEqual(APRSTypeBucket.of(code: "Y"), .vehicle)   // yacht is still a vehicle
        XCTAssertEqual(APRSTypeBucket.of(code: "-"), .fixed)     // house
        XCTAssertEqual(APRSTypeBucket.of(code: "/"), .fixed)
    }

    func testWeatherOutranksItsFixedClass() {
        // "_" classifies .fixed but must bucket as weather so it gets its own
        // colour and toggle.
        XCTAssertEqual(APRSStationClass.classify(code: "_", hasMotion: false), .fixed)
        XCTAssertEqual(APRSTypeBucket.of(code: "_"), .weather)
    }

}
