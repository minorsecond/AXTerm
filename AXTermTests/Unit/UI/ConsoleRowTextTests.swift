#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import Combine
@testable import AXTerm

/// How a console row holds its message text.
///
/// Each row used to carry an NSTextView and set its text when the table built
/// the row. Changing a text view's text moves its selection, AppKit tells any
/// accessibility client (Magnet, AltTab, a screen reader) that the selection
/// changed, and the client asks the table for its rows while the table is
/// still making this one. NSTableView throws, and A (705) quit in the middle
/// of the park test (2026-10-10). Rows now draw their text; a text view is put
/// over a row only when someone clicks into it to select, never while the
/// table is building rows.
@MainActor
final class ConsoleRowTextTests: XCTestCase {

    final class Feed: ObservableObject {
        @Published var items: [ConsoleTableItem] = []
        @Published var revision = 0
        @Published var following = true
        var opened: [String] = []
    }

    struct Harness: View {
        @ObservedObject var feed: Feed
        var body: some View {
            ConsoleTableView(items: feed.items, environment: env, fileNameIndex: nil,
                             actions: ConsoleTableActions(onIdentity: { feed.opened.append($0) }),
                             revision: feed.revision, isFollowing: $feed.following,
                             autoScroll: true, scrollToBottomToken: 0)
        }
        var env: ConsoleRowEnvironment {
            var e = ConsoleRowEnvironment()
            e.linksCallsigns = true
            e.heardCallsigns = ["W0NED"]
            return e
        }
    }

    private var window: NSWindow!
    private var feed: Feed!
    private var table: ConsoleNSTableView!

    private func line(_ text: String, at seconds: Double) -> ConsoleTableItem {
        let l = ConsoleLine.packet(from: "N0CALL", to: "K0EPI-2", text: text,
                                   timestamp: Date(timeIntervalSince1970: seconds))
        return .line(ConsoleLineGroup(primary: l), run: .alone, beaconRepeat: nil)
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    private func find(_ view: NSView) -> ConsoleNSTableView? {
        if let t = view as? ConsoleNSTableView { return t }
        for sub in view.subviews { if let t = find(sub) { return t } }
        return nil
    }

    override func setUp() async throws {
        feed = Feed()
        feed.items = (0..<40).map { line("Line \($0) from the node, see W0NED for the route", at: Double($0)) }
        let host = NSHostingView(rootView: Harness(feed: feed).frame(width: 900, height: 500))
        window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 900, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        settle()
        table = find(host)
        XCTAssertNotNil(table)
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
    }

    private var visibleCells: [ConsoleLineCellView] {
        var cells: [ConsoleLineCellView] = []
        table.enumerateAvailableRowViews { rowView, _ in
            if let cell = rowView.view(atColumn: 0) as? ConsoleLineCellView { cells.append(cell) }
        }
        return cells
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    /// Building and rebuilding rows touches no text view.
    func testRowsOnScreenHoldNoTextView() {
        XCTAssertFalse(visibleCells.isEmpty)
        XCTAssertTrue(visibleCells.allSatisfy { textViews(in: $0).isEmpty })
        feed.items += [line("one more", at: 100)]
        feed.revision += 1
        settle()
        XCTAssertTrue(visibleCells.allSatisfy { textViews(in: $0).isEmpty })
    }

    /// A callsign in the message is still a link: found under the pointer,
    /// and a click on it opens the station.
    func testALinkInADrawnRowIsClickable() throws {
        let cell = try XCTUnwrap(visibleCells.last)
        let rect = try XCTUnwrap(cell.linkRects.first)
        XCTAssertEqual(cell.link(at: NSPoint(x: rect.midX, y: rect.midY)).flatMap(ConsoleCallsignLink.callsign(from:)),
                       "W0NED")
        XCTAssertNil(cell.link(at: NSPoint(x: rect.minX - 40, y: rect.midY)))
        XCTAssertTrue(cell.open(at: NSPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(feed.opened, ["W0NED"])
    }

    /// Clicking into a message puts a selectable text view over it, holding
    /// the row's text; the next change to the table takes it away first.
    func testSelectingTextUsesAnOverlayThatLeavesBeforeTheTableChanges() throws {
        let cell = try XCTUnwrap(visibleCells.last)
        let row = table.row(for: cell)
        let overlay = try XCTUnwrap(table.beginSelection(inRow: row))
        XCTAssertTrue(overlay.isSelectable)
        XCTAssertFalse(overlay.isEditable)
        XCTAssertTrue(overlay.string.hasPrefix("Line 39"))
        XCTAssertNotNil(overlay.superview)

        feed.items += [line("another", at: 200)]
        feed.revision += 1
        settle()
        XCTAssertNil(overlay.superview, "removed before rows were rebuilt")
        XCTAssertTrue(visibleCells.allSatisfy { textViews(in: $0).isEmpty })
    }

    /// A click on a row away from its message and its callsign, where the
    /// row has nothing to do with it. The row passed it on to the table and
    /// the table handed it back to the row, about ten thousand times over,
    /// until A (705) ran out of stack (remote access test, 2026-10-11).
    func testAClickOnARowsEmptySpaceIsHarmless() throws {
        let cell = try XCTUnwrap(visibleCells.last)
        let inCell = NSPoint(x: 1, y: cell.bounds.midY)
        XCTAssertFalse(cell.messageFrame.contains(inCell), "away from the message")
        let inWindow = cell.convert(inCell, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        cell.mouseDown(with: event)
        table.mouseDown(with: event)
        XCTAssertTrue(feed.opened.isEmpty)
    }
}
#endif
