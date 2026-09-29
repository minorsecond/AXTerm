//
//  NWSForecastPlaceTests.swift
//  AXTermTests
//
//  A state forecast lists two dozen cities across seven days. Rendered as one
//  grid it forced a horizontal scroll where a row and its column header could
//  never be on screen together, so the view now opens on a single place.
//

import XCTest
@testable import AXTerm

final class NWSForecastPlaceTests: XCTestCase {

    private func forecast(_ names: [String]) -> NWSTabularForecast {
        NWSTabularForecast(
            productId: "SFTCO", title: "Tabular State Forecast for Colorado",
            office: "NWS Denver/Boulder CO", issued: "1247 AM MDT",
            days: [],
            sections: [.init(title: "NORTHEAST COLORADO",
                             places: names.map { .init(name: $0, cells: []) })])
    }

    func testTheOperatorsOwnTownOpensFirst() {
        let f = forecast(["DENVER", "BURLINGTON", "AURORA"])
        XCTAssertEqual(f.defaultPlace(preferring: "Aurora")?.name, "AURORA")
    }

    func testMatchingIgnoresCase() {
        // The product shouts; a licence record does not.
        let f = forecast(["COLORADO SPRINGS"])
        XCTAssertEqual(f.defaultPlace(preferring: "Colorado Springs")?.name,
                       "COLORADO SPRINGS")
    }

    func testAPartialNameStillFinds() {
        let f = forecast(["DENVER", "PUEBLO"])
        XCTAssertEqual(f.defaultPlace(preferring: "Denver Intl")?.name, "DENVER")
    }

    func testAnUnknownTownFallsBackToTheFirstPlace() {
        let f = forecast(["DENVER", "PUEBLO"])
        XCTAssertEqual(f.defaultPlace(preferring: "Reykjavik")?.name, "DENVER")
    }

    func testNoLocalityFallsBackToTheFirstPlace() {
        let f = forecast(["DENVER", "PUEBLO"])
        XCTAssertEqual(f.defaultPlace(preferring: nil)?.name, "DENVER")
        XCTAssertEqual(f.defaultPlace(preferring: "   ")?.name, "DENVER")
    }

    func testAnEmptyProductHasNoDefault() {
        XCTAssertNil(forecast([]).defaultPlace(preferring: "Denver"))
    }

    func testAllPlacesFlattensEverySection() {
        let f = NWSTabularForecast(
            productId: "SFTCO", title: "t", office: "", issued: "", days: [],
            sections: [
                .init(title: "NORTHEAST", places: [.init(name: "DENVER", cells: [])]),
                .init(title: "SOUTHEAST", places: [.init(name: "PUEBLO", cells: [])]),
            ])
        XCTAssertEqual(f.allPlaces.map(\.name), ["DENVER", "PUEBLO"])
        XCTAssertEqual(f.sectionTitle(for: f.allPlaces[1]), "SOUTHEAST")
    }
}
