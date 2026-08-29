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
}
