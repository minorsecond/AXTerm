//
//  MainWindowFitsTests.swift
//  AXTermTests
//
//  The main window must fit the screen. On a 1920x1080 display it asked for
//  more height than the 1,050 points under the menu bar: Zoom made it 1,440
//  tall, hanging the compose bar off the bottom of the screen, and zooming
//  back to the screen's height laid the content out taller than the window
//  and slid it up under the title bar (operator, 2026-10-10).
//

#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class MainWindowFitsTests: XCTestCase {

    private var savedCoordinator: SessionCoordinator?
    private var savedOpenAction: (() -> Void)?

    override func setUp() {
        super.setUp()
        savedCoordinator = SessionCoordinator.shared
        SessionCoordinator.shared = nil
        savedOpenAction = SettingsRouter.shared.openAction
    }

    override func tearDown() {
        SessionCoordinator.shared = savedCoordinator
        SettingsRouter.shared.openAction = savedOpenAction
        super.tearDown()
    }

    private func hostedWindow(height: CGFloat) -> (NSWindow, NSHostingController<AnyView>, StationServices) {
        let defaults = TestDefaults.make("MainWindowFits")
        defaults.set(false, forKey: AppSettingsStore.persistKey)
        let settings = AppSettingsStore(defaults: defaults)
        settings.myCallsign = "K0EPI"
        // Switched off and pointed nowhere: nothing here may open a link.
        for radio in settings.radios {
            settings.updateRadio(radio.id) { $0.enabled = false; $0.host = "127.0.0.1"; $0.port = 9 }
        }
        let winlink = WinlinkContext(
            store: nil,
            settings: WinlinkSettings(defaults: defaults,
                                      keychain: KeychainStore(service: "test-\(UUID().uuidString)")),
            profile: StationProfile(defaults: defaults))
        let client = PacketEngine(settings: settings)
        let bbs = BBSSettings(defaults: defaults)
        let station = StationServices(client: client, settings: settings, winlinkContext: winlink, bbsSettings: bbs)
        let root = AnyView(ContentView(client: client, settings: settings, inspectionRouter: PacketInspectionRouter(),
                                       winlinkContext: winlink, bbsSettings: bbs, station: station)
            .defaultAppStorage(defaults))
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.minSize, .intrinsicContentSize]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: height),
                              styleMask: [.titled, .resizable, .miniaturizable, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1400, height: height))
        return (window, controller, station)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The smallest height the window allows fits a 13-inch laptop's screen,
    /// with the map mounted (it is kept alive behind every page after 3 s).
    func testTheMainWindowFitsASmallScreen() {
        let (window, _, station) = hostedWindow(height: 700)
        defer { window.close(); station.stop() }
        spin(4)
        XCTAssertLessThanOrEqual(window.contentMinSize.height, 760,
                                 "the main window asks for at least \\(window.contentMinSize.height) points of height")
    }

    // MARK: - Keeping the frame on its screen

    /// The right-hand 1920x1080 display, AppKit coordinates (origin at the
    /// bottom left of the main screen).
    private let screen = NSRect(x: 1920, y: 0, width: 1920, height: 1080)

    /// Zoom made the window 1,440 tall with its top under the menu bar:
    /// clamped to the screen, top kept where it was.
    func testAFrameTallerThanItsScreenIsClamped() {
        let tooTall = NSRect(x: 1920, y: -390, width: 1920, height: 1440)
        XCTAssertEqual(MainWindowFit.clamped(tooTall, visible: screen), NSRect(x: 1920, y: 0, width: 1920, height: 1080))
    }

    func testAFrameThatFitsIsLeftAlone() {
        XCTAssertNil(MainWindowFit.clamped(NSRect(x: 1920, y: 20, width: 1900, height: 1030), visible: screen))
        XCTAssertNil(MainWindowFit.clamped(NSRect(x: 2000, y: 100, width: 900, height: 600), visible: screen))
    }

    /// Hanging off the bottom only: moved up onto the screen, size kept.
    func testAFrameHangingOffTheBottomMovesUp() {
        let low = NSRect(x: 2000, y: -200, width: 900, height: 700)
        XCTAssertEqual(MainWindowFit.clamped(low, visible: screen), NSRect(x: 2000, y: 0, width: 900, height: 700))
    }

    func testAFrameWiderThanItsScreenIsNarrowed() {
        let wide = NSRect(x: 1800, y: 100, width: 2400, height: 700)
        XCTAssertEqual(MainWindowFit.clamped(wide, visible: screen), NSRect(x: 1920, y: 100, width: 1920, height: 700))
    }
}
#endif