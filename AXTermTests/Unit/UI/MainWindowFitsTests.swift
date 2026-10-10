//
//  MainWindowFitsTests.swift
//  AXTermTests
//
//  The main window must fit the screen. With a connected APRS radio it asked
//  for more height than a 1920x1080 display has: Zoom made it 1,440 tall,
//  hanging the compose bar off the bottom of the screen, and zooming back
//  laid the content out taller than the window and slid it up under the
//  title bar (operator, 2026-10-10). SwiftUI sizes a window's minimum at the
//  narrowest width, where a line of text allowed to grow without limit wraps
//  a word per line.
//

#if os(macOS)
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class MainWindowFitsTests: XCTestCase {

    /// The smallest height SwiftUI allows a window showing `view`.
    private func minimumHeight<V: View>(_ view: V) -> CGFloat {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.minSize, .intrinsicContentSize]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        defer { window.close() }
        return window.contentMinSize.height
    }

    /// The compose bar's APRS-channel notice let its text grow without
    /// limit. Sized at the narrowest width, that one line needed 1,209
    /// points, more than the screen.
    func testTheComposeNoticeNeedsLittleHeight() {
        let banner = ComposeNoticeBanner(
            text: "IC-705 is on the APRS channel; connected sessions are off. Switch it to Packet to connect.",
            systemImage: "antenna.radiowaves.left.and.right.slash", tint: .orange,
            actionTitle: "Switch to Packet", actionHelp: "", action: {})
        XCTAssertLessThan(minimumHeight(VStack { banner; Color.clear }), 80)
    }

    /// The map is kept mounted behind every page; nothing in it may decide
    /// how tall the window must be.
    func testTheKeptAliveLayerDoesNotSizeThePage() {
        let tall = Text(String(repeating: "A map banner that wraps. ", count: 20))
            .fixedSize(horizontal: false, vertical: true)
        XCTAssertLessThan(minimumHeight(Color.clear.keptAliveLayer { tall }), 80)
    }

    // MARK: - Keeping the hidden map still

    private final class Box: ObservableObject {
        @Published var width: CGFloat = 1000
        @Published var active = false
        var layerSizes: [CGSize] = []
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        var body: some View {
            Color.clear.frame(width: box.width, height: 400)
                .keptAliveLayer(active: box.active) {
                    Color.clear.onGeometryChange(for: CGSize.self, of: { $0.size }) { box.layerSizes.append($0) }
                }
                .frame(width: 1200, height: 400, alignment: .leading)
        }
    }

    /// The map is kept mounted behind every page. Hiding the sidebar
    /// animates the page's width, and the hidden map was resized, and
    /// MapKit re-rendered it, on every frame: about 460 ms of main-thread
    /// work per toggle on the Packets page (2026-10-10). While its page is
    /// not showing, the kept layer holds its size.
    func testAnInactiveKeptLayerHoldsItsSizeWhenThePageResizes() {
        let box = Box()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Harness(box: box))
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(box.layerSizes.last?.width, 1000)

        box.width = 760          // the sidebar comes back
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(box.layerSizes.last?.width, 1000, "hidden: not resized")

        box.active = true        // its page opens
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(box.layerSizes.last?.width, 760, "showing: follows the page")
    }
}
#endif
