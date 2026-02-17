//
//  ConsoleVisibilityFilterTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

final class ConsoleVisibilityFilterTests: XCTestCase {
    func testApplyIncludesAllWhenAllTogglesEnabled() {
        let lines = sampleLines()
        let flags = ConsoleTypeFilterFlags()

        let result = ConsoleVisibilityFilter.apply(lines: lines, clearedAt: nil, flags: flags)

        XCTAssertEqual(result.count, lines.count)
    }

    func testApplyHidesDataWhenDataToggleOff() {
        let lines = sampleLines()
        var flags = ConsoleTypeFilterFlags()
        flags.showData = false

        let result = ConsoleVisibilityFilter.apply(lines: lines, clearedAt: nil, flags: flags)

        XCTAssertFalse(result.contains(where: { $0.messageType == .data }))
        XCTAssertTrue(result.contains(where: { $0.messageType == .id }))
        XCTAssertTrue(result.contains(where: { $0.messageType == .beacon }))
    }

    func testApplyHidesSystemAndErrorWhenSystemToggleOff() {
        let lines = sampleLines()
        var flags = ConsoleTypeFilterFlags()
        flags.showSystem = false

        let result = ConsoleVisibilityFilter.apply(lines: lines, clearedAt: nil, flags: flags)

        XCTAssertFalse(result.contains(where: { $0.kind == .system || $0.kind == .error }))
        XCTAssertTrue(result.contains(where: { $0.kind == .packet }))
    }

    func testApplyRespectsClearedAtCutoff() {
        let now = Date()
        let old = ConsoleLine.packet(from: "A", to: "B", text: "old", timestamp: now.addingTimeInterval(-60))
        let fresh = ConsoleLine.packet(from: "A", to: "B", text: "fresh payload data", timestamp: now)
        let lines = [old, fresh]

        let result = ConsoleVisibilityFilter.apply(
            lines: lines,
            clearedAt: now.addingTimeInterval(-30),
            flags: ConsoleTypeFilterFlags()
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.text, "fresh payload data")
    }

    private func sampleLines() -> [ConsoleLine] {
        [
            .packet(from: "N0CALL", to: "ID", text: "N0CALL ID"),
            .packet(from: "N0CALL", to: "BEACON", text: "BEACON hello"),
            .packet(from: "BBS", to: "ME", text: "MAIL FOR: ME"),
            .packet(from: "ALICE", to: "BOB", text: "This is actual content data"),
            .packet(from: "NODE", to: "ME", text: "ENTER COMMAND >"),
            .packet(from: "X", to: "Y", text: "OK"),
            .system("RX: PEER → ME: RR(1)"),
            .error("Connection failed")
        ]
    }
}
