import XCTest
@testable import AXTerm

/// The grid the map labels this station with: the grid of the position in
/// use, not the one typed in Settings. On 2026-10-09 Station C's exact
/// coordinate was in Alabama and the map still labeled it DM79PO.
final class StationLabelTests: XCTestCase {

    func testTheLabelIsTheGridOfThePositionInUse() {
        XCTAssertEqual(StationLabel.grid(at: GreatCircle.Point(latitude: 31.4920, longitude: -87.4139),
                                         settingsGrid: "DM79po"), "EM61HL")
    }

    /// At the grid's own center the two agree.
    func testAtTheGridCenterItIsTheSettingsGrid() {
        XCTAssertEqual(StationLabel.grid(at: GreatCircle.Point(latitude: 39.6042, longitude: -104.7083),
                                         settingsGrid: "DM79po"), "DM79PO")
    }

    func testWithNoPositionTheSettingsGridStands() {
        XCTAssertEqual(StationLabel.grid(at: nil, settingsGrid: "dm79po"), "DM79PO")
    }
}
