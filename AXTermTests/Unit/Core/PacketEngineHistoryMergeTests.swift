//
//  PacketEngineHistoryMergeTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

final class PacketEngineHistoryMergeTests: XCTestCase {
    func testMergeLoadedConsoleLinesKeepsLiveLineWhenHistoryLoads() {
        let base = Date()
        let loaded = [
            ConsoleLine.packet(from: "A", to: "B", text: "history-1", timestamp: base.addingTimeInterval(-10)),
            ConsoleLine.packet(from: "A", to: "B", text: "history-2", timestamp: base.addingTimeInterval(-5))
        ]
        let live = [
            ConsoleLine.packet(from: "X", to: "Y", text: "live-rx", timestamp: base)
        ]

        let merged = PacketEngine.mergeLoadedConsoleLines(loaded, into: live, maxLines: 10)

        XCTAssertEqual(merged.count, 3)
        XCTAssertTrue(merged.contains(where: { $0.text == "live-rx" }))
        XCTAssertEqual(merged.last?.text, "live-rx")
    }

    func testMergeLoadedConsoleLinesRespectsCap() {
        let base = Date()
        let loaded = (0..<5).map { i in
            ConsoleLine.packet(from: "A", to: "B", text: "h\(i)", timestamp: base.addingTimeInterval(TimeInterval(i)))
        }
        let live = (0..<5).map { i in
            ConsoleLine.packet(from: "X", to: "Y", text: "l\(i)", timestamp: base.addingTimeInterval(TimeInterval(100 + i)))
        }

        let merged = PacketEngine.mergeLoadedConsoleLines(loaded, into: live, maxLines: 4)

        XCTAssertEqual(merged.count, 4)
        XCTAssertTrue(merged.allSatisfy { $0.text.hasPrefix("l") })
    }
}
