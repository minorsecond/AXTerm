import XCTest
@testable import AXTerm

/// The iOS map's toolbar. On an iPad the centered tab bar leaves room for
/// three items, and a fourth folded Layers and More into an overflow menu,
/// an extra tap for the control used most. Car Mode, an occasional mode
/// there, moves into More instead (Apple's guidance: keep the frequent
/// controls in the bar, put the occasional ones in a menu).
final class MapToolbarLayoutTests: XCTestCase {

    func testAPhoneShowsAllFour() {
        XCTAssertEqual(MapToolbarLayout.barItems(regularWidth: false), [.carMode, .stations, .layers, .more])
        XCTAssertFalse(MapToolbarLayout.carModeInMore(regularWidth: false))
    }

    func testAnIPadKeepsLayersInTheBarAndPutsCarModeInMore() {
        XCTAssertEqual(MapToolbarLayout.barItems(regularWidth: true), [.stations, .layers, .more])
        XCTAssertTrue(MapToolbarLayout.carModeInMore(regularWidth: true))
    }
}
