import XCTest
@testable import AXTerm

final class StationAddressTests: XCTestCase {

    func testMapsAPlacemarkOntoTheFormFields() {
        let address = StationAddress.from(.init(
            subThoroughfare: "1600",
            thoroughfare: "Pennsylvania Avenue NW",
            locality: "Washington",
            administrativeArea: "DC",
            subAdministrativeArea: "District of Columbia",
            postalCode: "20500"))

        XCTAssertEqual(address.street, "1600 Pennsylvania Avenue NW")
        XCTAssertEqual(address.city, "Washington")
        XCTAssertEqual(address.state, "DC")
        XCTAssertEqual(address.postalCode, "20500")
    }

    /// ICS forms want the county name; the field label already says
    /// "County", so "Jefferson County" would read as a stutter.
    func testCountySuffixIsStripped() {
        XCTAssertEqual(
            StationAddress.from(.init(subAdministrativeArea: "Jefferson County")).county,
            "Jefferson")
        XCTAssertEqual(
            StationAddress.from(.init(subAdministrativeArea: "Orleans Parish")).county,
            "Orleans")
        XCTAssertEqual(
            StationAddress.from(.init(subAdministrativeArea: "Matanuska-Susitna Borough")).county,
            "Matanuska-Susitna")
    }

    /// A county that simply contains the word must not be truncated.
    func testCountyWithoutASuffixIsUnchanged() {
        XCTAssertEqual(
            StationAddress.from(.init(subAdministrativeArea: "Doña Ana")).county, "Doña Ana")
        XCTAssertEqual(
            StationAddress.from(.init(subAdministrativeArea: "County Cork")).county, "County Cork")
    }

    /// Outside the US the geocoder returns a region name rather than a
    /// two-letter code. Pass it through rather than inventing a mapping.
    func testNonUSRegionsPassThroughUnchanged() {
        let address = StationAddress.from(.init(
            locality: "Reykjavík", administrativeArea: "Capital Region"))
        XCTAssertEqual(address.state, "Capital Region")
        XCTAssertEqual(address.city, "Reykjavík")
    }

    func testMissingFieldsBecomeEmptyNotNil() {
        let address = StationAddress.from(.init(locality: "Denver"))
        XCTAssertEqual(address.city, "Denver")
        XCTAssertEqual(address.street, "")
        XCTAssertEqual(address.county, "")
        XCTAssertFalse(address.isEmpty)
    }

    func testAnEmptyPlacemarkIsEmpty() {
        XCTAssertTrue(StationAddress.from(.init()).isEmpty)
    }

    func testStreetNumberWithoutAStreetNameDoesNotLeaveStrayWhitespace() {
        XCTAssertEqual(StationAddress.from(.init(subThoroughfare: "1600")).street, "1600")
        XCTAssertEqual(StationAddress.from(.init(thoroughfare: "Main St")).street, "Main St")
    }

    func testWhitespaceIsTrimmed() {
        let address = StationAddress.from(.init(locality: "  Denver  ", administrativeArea: " CO "))
        XCTAssertEqual(address.city, "Denver")
        XCTAssertEqual(address.state, "CO")
    }
}
