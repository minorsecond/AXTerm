//
//  TransferRowNameFitsTests.swift
//  AXTermTests
//
//  On the iPhone a finished transfer's name was cut to "t20k_…n.bin": the
//  status badge and info button share its line. Where the whole row does
//  not fit, the name keeps the first line and the status and buttons take
//  a second (smoke run 2026-10-03-1, F5, issue 109).
//

#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import AXTerm

@MainActor
final class TransferRowNameFitsTests: XCTestCase {

    private func finished() -> BulkTransfer {
        var transfer = BulkTransfer(id: UUID(), fileName: "t20k_bin.bin", fileSize: 20_480,
                                    destination: "K0EPI-2", direction: .inbound)
        transfer.markCompleted()
        return transfer
    }

    private func height(atWidth width: CGFloat) -> CGFloat {
        let row = BulkTransferRow(transfer: finished(), onPause: {}, onResume: {}, onCancel: {})
            .frame(width: width)
        let hosting = NSHostingView(rootView: row)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    /// The Mac's 13-point text fits this row on one line from about 320
    /// points; the iPhone's 17-point text needs more than its 360. Just
    /// short of the row's width the old header kept one line by cutting
    /// the name; much shorter, it wrapped its badges into three or four.
    func testJustTooNarrowGivesTheNameItsOwnLine() {
        XCTAssertGreaterThan(height(atWidth: 300), height(atWidth: 900) + 10)
    }

    func testVeryNarrowStaysTwoTidyLines() {
        XCTAssertLessThanOrEqual(height(atWidth: 200), 60, "name on one line, status and buttons on the next")
    }

    func testAWideRowStaysOnOneLine() {
        XCTAssertEqual(height(atWidth: 900), height(atWidth: 700), accuracy: 0.5)
    }
}
#endif
