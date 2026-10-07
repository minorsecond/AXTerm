//
//  CompactTerminalLayoutTests.swift
//  AXTermTests
//
//  How the terminal arranges itself at phone width (smoke run 2026-10-03-1,
//  issue 106): on an iPhone the top row was wider than the screen, the
//  compose area was four rows deep with a 70-point message field, and the
//  TX queue kept finished entries on screen at half the screen's height.
//

import XCTest
@testable import AXTerm

final class CompactTerminalLayoutTests: XCTestCase {

    // MARK: Top row

    func testOnAPhoneTheSessionPickerFoldsIntoAMenu() {
        XCTAssertEqual(CompactTerminalLayout.sessionControl(tab: .session, hasRecords: true, compact: true), .menu)
        XCTAssertEqual(CompactTerminalLayout.sessionControl(tab: .session, hasRecords: true, compact: false), .inline)
        XCTAssertEqual(CompactTerminalLayout.sessionControl(tab: .session, hasRecords: false, compact: true), .none)
        XCTAssertEqual(CompactTerminalLayout.sessionControl(tab: .transfers, hasRecords: true, compact: true), .none,
                       "only the session pane picks a session")
    }

    // MARK: Compose area

    func testWithALinkUpAPhoneDropsTheRowsThatCannotChange() {
        let rows = CompactTerminalLayout.composeRows(compact: true, sessionMode: true, linkUp: true)
        XCTAssertFalse(rows.destination, "the station is in the session header")
        XCTAssertFalse(rows.routingPicker, "the route is fixed while the link is up")
        XCTAssertTrue(rows.accessoriesInMenu)
    }

    func testWithNoLinkAPhoneStillChoosesWhoAndHow() {
        let rows = CompactTerminalLayout.composeRows(compact: true, sessionMode: true, linkUp: false)
        XCTAssertTrue(rows.destination)
        XCTAssertTrue(rows.routingPicker)
        XCTAssertTrue(rows.accessoriesInMenu)
    }

    func testBroadcastHasNoDestinationOrRouteRows() {
        let rows = CompactTerminalLayout.composeRows(compact: true, sessionMode: false, linkUp: false)
        XCTAssertFalse(rows.destination)
        XCTAssertFalse(rows.routingPicker)
    }

    func testAWideWindowKeepsEveryControlInline() {
        for linkUp in [false, true] {
            let rows = CompactTerminalLayout.composeRows(compact: false, sessionMode: true, linkUp: linkUp)
            XCTAssertTrue(rows.destination)
            XCTAssertTrue(rows.routingPicker)
            XCTAssertFalse(rows.accessoriesInMenu)
        }
    }

    // MARK: Console rows

    func testOnAPhoneTheMessageGoesUnderItsHeader() {
        XCTAssertTrue(CompactTerminalLayout.stacksMessageUnderHeader(compact: true))
        XCTAssertFalse(CompactTerminalLayout.stacksMessageUnderHeader(compact: false))
    }

    // MARK: Session strip

    func testALiveLinkStaysOnScreenInBroadcastMode() {
        XCTAssertTrue(CompactTerminalLayout.showsSessionStrip(sessionMode: false, linkUp: true),
                      "switching the bar to Broadcast does not end the link")
        XCTAssertTrue(CompactTerminalLayout.showsSessionStrip(sessionMode: true, linkUp: false))
        XCTAssertFalse(CompactTerminalLayout.showsSessionStrip(sessionMode: false, linkUp: false))
    }

    // MARK: TX queue

    func testTheQueueShowsOnlyWhileSomethingIsStillGoingOut() {
        XCTAssertFalse(TxQueuePresentation.isVisible(statuses: []))
        XCTAssertFalse(TxQueuePresentation.isVisible(statuses: [.sent, .acked, .failed, .cancelled]),
                       "finished entries alone do not hold half the screen")
        XCTAssertTrue(TxQueuePresentation.isVisible(statuses: [.acked, .queued]))
        XCTAssertTrue(TxQueuePresentation.isVisible(statuses: [.sending]))
        XCTAssertTrue(TxQueuePresentation.isVisible(statuses: [.awaitingAck]))
    }
}
