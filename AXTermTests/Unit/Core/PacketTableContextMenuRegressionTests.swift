//
//  PacketTableContextMenuRegressionTests.swift
//  AXTermTests
//
//  Created by Codex on 2/11/26.
//

import AppKit
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class PacketTableContextMenuRegressionTests: XCTestCase {
    private final class Box<Value> {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private final class StubTableView: NSTableView {
        var forcedRow: Int = -1

        override func row(at point: NSPoint) -> Int {
            forcedRow
        }
    }

    func testPacketNSTableViewCoordinatorDefersApplyPendingUpdateDuringContextMenuTracking() {
        let selectionBox = Box<Set<Packet.ID>>([])
        let isAtBottomBox = Box<Bool>(true)
        let followNewestBox = Box<Bool>(true)

        let coordinator = PacketNSTableView.Coordinator(
            selection: Binding(
                get: { selectionBox.value },
                set: { selectionBox.value = $0 }
            ),
            isAtBottom: Binding(
                get: { isAtBottomBox.value },
                set: { isAtBottomBox.value = $0 }
            ),
            followNewest: Binding(
                get: { followNewestBox.value },
                set: { followNewestBox.value = $0 }
            ),
            onInspectSelection: {},
            onCopyInfo: { _ in },
            onCopyRawHex: { _ in }
        )

        let tableView = NSTableView()
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        let menu = NSMenu()
        tableView.menu = menu
        coordinator.attach(tableView: tableView)

        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        coordinator.enqueueUpdate(packets: [makePacket(index: 10)], selection: [], scrollToBottomToken: 0)
        waitForMainQueue(seconds: 0.20)
        XCTAssertEqual(coordinator.rows.count, 0, "Pending update should not apply while context menu is active.")

        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        waitForMainQueue(seconds: 0.20)
        XCTAssertEqual(coordinator.rows.count, 1)
    }

    func testPacketNSTableViewCoordinatorMenuForEventReturnsNilForOutOfBoundsRow() {
        let coordinator = PacketNSTableView.Coordinator(
            selection: .constant([]), isAtBottom: .constant(true), followNewest: .constant(true),
            onInspectSelection: {}, onCopyInfo: { _ in }, onCopyRawHex: { _ in })
        let tableView = StubTableView()
        tableView.menu = NSMenu()
        coordinator.attach(tableView: tableView)

        let packets = [makePacket(index: 1)]
        coordinator.rows = packets.map { PacketRowViewModel.fromPacket($0) }

        tableView.forcedRow = packets.count
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        XCTAssertNotNil(event)
        XCTAssertNil(coordinator.tableView(tableView, menuFor: event!))
    }

    private func waitForMainQueue(seconds: TimeInterval) {
        let expectation = XCTestExpectation(description: "Main queue wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: seconds + 1.0)
    }

    private func makePacket(index: Int) -> Packet {
        Packet(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
            from: AX25Address(call: "N0C\(index)"),
            to: AX25Address(call: "W0A\(index)"),
            info: Data("payload-\(index)".utf8)
        )
    }
}
