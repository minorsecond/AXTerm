import XCTest
@testable import AXTerm

/// " on IC-705, Base" after a notice that several radios carried something.
final class RadioSuffixTests: XCTestCase {

    /// A radio left with no name is called what the rest of the app calls it,
    /// not nothing: the beacon notice read "sent via WIDE1-1 on ." (2026-10-10).
    func testAnUnnamedRadioUsesItsDefaultName() {
        let unnamed = RadioProfile(id: RadioID(rawValue: "a"), name: "")
        let suffix = SessionCoordinator.radioSuffix(for: [unnamed])
        XCTAssertEqual(suffix, " on \(RadioProfile.defaultName(for: unnamed))")
    }

    func testNamedRadiosAreListed() {
        let a = RadioProfile(id: RadioID(rawValue: "a"), name: "IC-705")
        let b = RadioProfile(id: RadioID(rawValue: "b"), name: "ID-50")
        XCTAssertEqual(SessionCoordinator.radioSuffix(for: [a, b]), " on IC-705, ID-50")
        XCTAssertEqual(SessionCoordinator.radioSuffix(for: []), "")
    }
}
