import XCTest
import AppKit
@testable import AXTerm

/// The menu bar item, owned by AppKit instead of SwiftUI's MenuBarExtra.
///
/// Regression pins for the launch-time freeze of 2026-08-29: SwiftUI's
/// MenuBarExtraController re-set the status button image during every
/// window's render flush, and a packet flood produced enough flushes in
/// one display cycle to trip AppKit's update-constraints loop guard on
/// the 32×24 status window — thrown as an NSException that stalled the
/// whole app. The contract these tests pin: the button image is set
/// exactly once for the life of the item, and the menu reads live state
/// only at the moment it opens.
@MainActor
final class StatusItemControllerTests: XCTestCase {

    private func makeController() -> (StatusItemController, PacketEngine) {
        let settings = AppSettingsStore(defaults: UserDefaults(suiteName: "status-item-tests")!)
        let client = PacketEngine(settings: settings)
        let controller = StatusItemController(
            client: client,
            settings: settings,
            inspectionRouter: PacketInspectionRouter())
        return (controller, client)
    }

    func testTheButtonImageIsSetExactlyOnceForTheLifeOfTheItem() async {
        let (controller, _) = makeController()
        controller.setInserted(true)
        defer { controller.setInserted(false) }

        let menu = NSMenu()
        for _ in 0..<5 { controller.menuNeedsUpdate(menu) }

        XCTAssertEqual(controller.buttonImageSetCount, 1,
                       "re-setting the status image per update is the storm "
                       + "that froze the app — once, ever")
    }

    func testInsertionFollowsTheSetting() async {
        let (controller, _) = makeController()
        controller.setInserted(true)
        XCTAssertTrue(controller.isInserted)
        controller.setInserted(false)
        XCTAssertFalse(controller.isInserted)
    }

    func testTheMenuIsBuiltFromLiveStateWhenItOpens() async {
        let (controller, _) = makeController()
        controller.setInserted(true)
        defer { controller.setInserted(false) }

        let menu = NSMenu()
        controller.menuNeedsUpdate(menu)
        let titles = menu.items.map(\.title)

        XCTAssertTrue(titles.contains("Open AXTerm"))
        XCTAssertTrue(titles.contains("Quit AXTerm"))
        XCTAssertTrue(titles.contains("Connect"),
                      "a disconnected engine offers Connect")
        XCTAssertTrue(titles.contains { $0.contains("Disconnected") },
                      "the status line names the connection state")
    }

    // MARK: - Pure menu model

    func testStatusTitlesMatchTheOldMenuExactly() {
        XCTAssertEqual(StatusItemController.MenuModel.statusTitle(for: .connected), "Connected")
        XCTAssertEqual(StatusItemController.MenuModel.statusTitle(for: .connecting), "Connecting")
        XCTAssertEqual(StatusItemController.MenuModel.statusTitle(for: .disconnected), "Disconnected")
        XCTAssertEqual(StatusItemController.MenuModel.statusTitle(for: .failed), "Connection Failed")
    }

    func testConnectionActionInvertsTheState() {
        XCTAssertEqual(StatusItemController.MenuModel.connectionAction(for: .connected), "Disconnect")
        XCTAssertEqual(StatusItemController.MenuModel.connectionAction(for: .connecting), "Disconnect")
        XCTAssertEqual(StatusItemController.MenuModel.connectionAction(for: .disconnected), "Connect")
        XCTAssertEqual(StatusItemController.MenuModel.connectionAction(for: .failed), "Connect")
    }


    // MARK: - Several radios (pure model)

    /// One radio through the array overloads is the header the menu has
    /// always shown.
    func testOneRadioKeepsTheHeaderItAlwaysHad() {
        let title = StatusItemController.MenuModel.headerTitle(
            radios: [.fixture(status: .connected)], packetCount: 42)
        XCTAssertEqual(title, "Connected \u{2014} 192.168.3.218:8001 \u{2022} 42 packets")
        XCTAssertEqual(StatusItemController.MenuModel.connectionAction(for: [.connected]), "Disconnect")
        XCTAssertEqual(StatusItemController.MenuModel.connectionAction(for: [.failed]), "Connect")
    }

    func testSeveralRadiosAreCountedInTheHeader() {
        let up = RadioStatusSummary.fixture(id: "a")
        let down = RadioStatusSummary.fixture(id: "b", name: "IC-705", status: .disconnected)
        XCTAssertEqual(StatusItemController.MenuModel.headerTitle(radios: [up, .fixture(id: "b")], packetCount: 7),
                       "2 radios connected \u{2022} 7 packets")
        XCTAssertEqual(StatusItemController.MenuModel.headerTitle(radios: [up, down], packetCount: 7),
                       "1 of 2 radios connected \u{2022} 7 packets")
    }

    /// ⌘K over several radios always means "stop" while anything is up or
    /// coming up, and "start" only when nothing is.
    func testConnectionActionOverSeveralRadiosActsOnAll() {
        XCTAssertEqual(StatusItemController.MenuModel.connectionAction(for: [.connected, .disconnected]),
                       "Disconnect All")
        XCTAssertEqual(StatusItemController.MenuModel.connectionAction(for: [.connecting, .failed]),
                       "Disconnect All")
        XCTAssertEqual(StatusItemController.MenuModel.connectionAction(for: [.disconnected, .failed]),
                       "Connect All")
    }
}
