#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import AXTerm

/// The packet table's cells. Hiding the sidebar on the Packets page
/// stuttered: the table's width changed on every frame of the animation,
/// and every visible cell was a text field pinned by four Auto Layout
/// constraints, a thousand or so to solve per frame, in cells built fresh
/// for each request rather than reused (2026-10-10).
@MainActor
final class PacketTableCellTests: XCTestCase {

    /// Hands back a cell it was given, as NSTableView's reuse queue does.
    private final class ReusingTable: NSTableView {
        var queued: [NSUserInterfaceItemIdentifier: NSView] = [:]
        override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
            queued.removeValue(forKey: identifier)
        }
    }

    private func coordinator(_ texts: [String]) -> PacketNSTableView.Coordinator {
        let coordinator = PacketNSTableView.Coordinator(
            selection: .constant([]), isAtBottom: .constant(true), followNewest: .constant(true),
            onInspectSelection: {}, onCopyInfo: { _ in }, onCopyRawHex: { _ in })
        coordinator.rows = texts.map { text in
            PacketRowViewModel.fromPacket(Packet(from: AX25Address(call: "K0EPI", ssid: 3), to: AX25Address(call: "APZAXT"),
                                                 frameType: .ui, control: 0x03, pid: 0xF0, info: Data(text.utf8)))
        }
        return coordinator
    }

    private func column(_ id: PacketNSTableView.ColumnIdentifier) -> NSTableColumn {
        NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
    }

    private func constraintCount(_ view: NSView) -> Int {
        view.constraints.count + view.subviews.reduce(0) { $0 + constraintCount($1) }
    }

    func testCellsUseNoAutoLayoutConstraints() throws {
        let coordinator = coordinator([">testing"])
        let table = NSTableView()
        for id in PacketNSTableView.ColumnIdentifier.allCases {
            let cell = try XCTUnwrap(coordinator.tableView(table, viewFor: column(id), row: 0), id.rawValue)
            XCTAssertEqual(constraintCount(cell), 0, "\(id.rawValue) cell has constraints")
        }
    }

    func testATextCellIsReusedAndRefilled() throws {
        let coordinator = coordinator([">first", ">second"])
        let table = ReusingTable()
        let first = try XCTUnwrap(coordinator.tableView(table, viewFor: column(.info), row: 0) as? NSTableCellView)
        XCTAssertEqual(first.textField?.stringValue, ">first")
        table.queued[first.identifier!] = first
        let second = try XCTUnwrap(coordinator.tableView(table, viewFor: column(.info), row: 1) as? NSTableCellView)
        XCTAssertTrue(second === first, "the queued cell is reused")
        XCTAssertEqual(second.textField?.stringValue, ">second")
    }

    func testATypeCellIsReused() throws {
        let coordinator = coordinator([">first", "!3953.87N/10458.21W-"])
        let table = ReusingTable()
        let first = try XCTUnwrap(coordinator.tableView(table, viewFor: column(.type), row: 0))
        table.queued[first.identifier!] = first
        let second = try XCTUnwrap(coordinator.tableView(table, viewFor: column(.type), row: 1))
        XCTAssertTrue(second === first)
    }
}
#endif
