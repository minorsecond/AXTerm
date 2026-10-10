#if os(macOS)
import XCTest
import SwiftUI
import AppKit
import Combine
@testable import AXTerm

/// The AppKit console in a real window: following the newest line, leaving a
/// reader alone, and keeping the bottom through width changes such as the
/// sidebar opening (it stopped following the first time, 2026-10-10).
@MainActor
final class ConsoleTableFollowTests: XCTestCase {

    final class Feed: ObservableObject {
        @Published var items: [ConsoleTableItem] = []
        @Published var revision = 0
        @Published var following = true
        @Published var token = 0
    }

    struct Harness: View {
        @ObservedObject var feed: Feed
        var body: some View {
            ConsoleTableView(items: feed.items, environment: ConsoleRowEnvironment(), fileNameIndex: nil,
                             actions: ConsoleTableActions(), revision: feed.revision,
                             isFollowing: $feed.following, autoScroll: true, scrollToBottomToken: feed.token)
        }
    }

    private var window: NSWindow!
    private var feed: Feed!
    private var scroll: NSScrollView!
    private var lineNumber = 0

    private func lines(_ count: Int) -> [ConsoleTableItem] {
        (0..<count).map { _ in
            lineNumber += 1
            let info = "!3953.70N/10505.14W>Beacon number \(lineNumber) with a comment that is long enough to wrap when narrow"
            let line = ConsoleLine.packet(from: "N0AMY-\(lineNumber % 9)", to: "APRS", text: info,
                                          timestamp: Date(timeIntervalSince1970: Double(lineNumber) * 10),
                                          via: ["WIDE1-1"], aprsInfo: Data(info.utf8))
            return .line(ConsoleLineGroup(primary: line), run: .alone, beaconRepeat: nil)
        }
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    private func append(_ count: Int) {
        feed.items += lines(count)
        feed.revision += 1
        settle()
    }

    private var clip: NSClipView { scroll.contentView }
    private var table: NSTableView { scroll.documentView as! NSTableView }
    private var documentBottom: CGFloat { table.rect(ofRow: table.numberOfRows - 1).maxY }
    private var isAtBottom: Bool { clip.bounds.maxY >= documentBottom - 2 }

    private func find(_ view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, s.documentView is NSTableView { return s }
        for sub in view.subviews { if let s = find(sub) { return s } }
        return nil
    }

    override func setUp() async throws {
        feed = Feed()
        feed.items = lines(300)
        let host = NSHostingView(rootView: Harness(feed: feed).frame(width: 900, height: 500))
        window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 900, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        settle()
        scroll = find(host)
        XCTAssertNotNil(scroll)
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
    }

    func testItOpensAtTheBottomAndFollowsNewLines() {
        XCTAssertTrue(isAtBottom)
        append(20)
        XCTAssertTrue(isAtBottom)
        XCTAssertTrue(feed.following)
    }

    func testScrollingUpLeavesTheReaderAlone() {
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY - 200))
        scroll.reflectScrolledClipView(clip)
        settle()
        XCTAssertFalse(feed.following)
        let before = clip.bounds.minY
        append(20)
        XCTAssertEqual(clip.bounds.minY, before, accuracy: 1, "new lines do not move a reader")
        XCTAssertFalse(feed.following)

        // The jump button: follow again and go to the newest.
        feed.following = true
        feed.token += 1
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(isAtBottom)
    }

    /// The sidebar opening or closing changes the width while following.
    func testWidthChangesKeepFollowing() {
        let table = self.table
        for width in [700.0, 1200.0, 640.0, 1000.0] {
            table.enclosingScrollView?.setFrameSize(NSSize(width: width, height: 500))
            table.sizeLastColumnToFit()
            settle()
            XCTAssertTrue(isAtBottom, "at the bottom at \(width)")
            XCTAssertTrue(feed.following, "following at \(width)")
        }
    }

    /// A reader keeps the row they were reading through a width change.
    func testWidthChangesKeepTheReadersRow() {
        // A long drag of the scroller, which AppKit brackets as a live scroll.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY - 1500))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        settle()
        XCTAssertFalse(feed.following)
        let row = table.rows(in: clip.bounds).location
        let offset = table.rect(ofRow: row).minY - clip.bounds.minY
        let before = "row \(row) top \(table.rect(ofRow: row).minY) clip \(clip.bounds.minY) width \(table.bounds.width)"
        scroll.setFrameSize(NSSize(width: 600, height: 500))
        table.sizeLastColumnToFit()
        settle()
        let after = "row top \(table.rect(ofRow: row).minY) clip \(clip.bounds.minY) width \(table.bounds.width) first \(table.rows(in: clip.bounds).location)"
        XCTAssertEqual(table.rect(ofRow: row).minY - clip.bounds.minY, offset, accuracy: 2, before + " → " + after)
        XCTAssertFalse(feed.following)
    }
}
#endif
