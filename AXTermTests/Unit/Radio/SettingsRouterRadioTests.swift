import XCTest
@testable import AXTerm

/// Deep links into the Radios pane name the radio they mean.
///
/// Exercised on the shared router rather than a fresh one: `SettingsRouter`
/// is main-actor isolated and a locally created instance is torn down from a
/// context that trips its deinit (the same trap noted for other isolated
/// classes in this project). The shared instance lives for the process, so
/// the tests restore what they change.
@MainActor
final class SettingsRouterRadioTests: XCTestCase {

    private var savedTab: SettingsTab = .general
    private var savedAction: (() -> Void)?

    override func setUp() {
        super.setUp()
        savedTab = SettingsRouter.shared.selectedTab
        savedAction = SettingsRouter.shared.openAction
        SettingsRouter.shared.openAction = nil
        SettingsRouter.shared.pendingRadio = nil
    }

    override func tearDown() {
        SettingsRouter.shared.pendingRadio = nil
        SettingsRouter.shared.selectedTab = savedTab
        SettingsRouter.shared.openAction = savedAction
        super.tearDown()
    }

    func testNavigatingToARadioLeavesItPendingForThePane() {
        let id = RadioID(rawValue: "ic705")
        SettingsRouter.shared.navigate(to: .radios, radio: id)
        XCTAssertEqual(SettingsRouter.shared.selectedTab, .radios)
        XCTAssertEqual(SettingsRouter.shared.pendingRadio, id)
    }

    /// A link to the pane without a radio does not pretend to have one.
    func testNavigatingToThePaneAloneLeavesNothingPending() {
        SettingsRouter.shared.navigate(to: .radios)
        XCTAssertEqual(SettingsRouter.shared.selectedTab, .radios)
        XCTAssertNil(SettingsRouter.shared.pendingRadio)
    }

    /// The pane is Radios with one radio or several: its home does not move
    /// when a second radio is added.
    func testThePaneIsRadiosWhateverTheCount() {
        XCTAssertEqual(SettingsTab.radios.settingsTitle, "Radios")
        XCTAssertEqual(SettingsTab.radios.settingsIcon, "radio")
    }
}
