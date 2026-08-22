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

    // MARK: - Digipeat Echoes

    /// The off-air copy of our own frame repeated by a digi (via marked `*`)
    /// is hidden by default; the TX-time line (via without `*`) always shows.
    func testDigipeatEchoOfOwnFrameHiddenByDefault() {
        let txLine = ConsoleLine.packet(from: "K0EPI-7", to: "KB5YZB-7", text: "RR(4) P/F",
                                        via: ["DRLNOD"], messageType: .prompt)
        let echo = ConsoleLine.packet(from: "K0EPI-7", to: "KB5YZB-7", text: "RR(4) P/F",
                                      via: ["DRLNOD*"], messageType: .prompt)
        let peerFrame = ConsoleLine.packet(from: "KB5YZB-7", to: "K0EPI-7", text: "I(4,5)",
                                           via: ["DRLNOD*"], messageType: .prompt)

        let result = ConsoleVisibilityFilter.apply(
            lines: [txLine, echo, peerFrame],
            clearedAt: nil,
            flags: ConsoleTypeFilterFlags(),
            localCallsign: "K0EPI-7"
        )

        XCTAssertEqual(result.count, 2, "only the digi echo of our own frame is hidden")
        XCTAssertTrue(result.contains(where: { $0.from == "K0EPI-7" && $0.via == ["DRLNOD"] }),
                      "our TX-time line must stay visible")
        XCTAssertTrue(result.contains(where: { $0.from == "KB5YZB-7" }),
                      "the peer's frame heard via the digi IS the session content — never hidden")
    }

    func testDigipeatEchoShownWhenToggleEnabled() {
        let echo = ConsoleLine.packet(from: "K0EPI-7", to: "KB5YZB-7", text: "RR(4) P/F",
                                      via: ["DRLNOD*"], messageType: .prompt)
        var flags = ConsoleTypeFilterFlags()
        flags.showDigipeats = true

        let result = ConsoleVisibilityFilter.apply(
            lines: [echo], clearedAt: nil, flags: flags, localCallsign: "K0EPI-7"
        )

        XCTAssertEqual(result.count, 1, "toggle on must reveal the digi's transmission")
    }

    func testEmptyLocalCallsignDisablesEchoHiding() {
        let echo = ConsoleLine.packet(from: "K0EPI-7", to: "KB5YZB-7", text: "RR(4) P/F",
                                      via: ["DRLNOD*"], messageType: .prompt)

        let result = ConsoleVisibilityFilter.apply(
            lines: [echo], clearedAt: nil, flags: ConsoleTypeFilterFlags(), localCallsign: ""
        )

        XCTAssertEqual(result.count, 1, "without a local callsign nothing can be classified as an echo")
    }

    func testDigipeatEchoDetectionNormalizesCallsign() {
        let echo = ConsoleLine.packet(from: "K0EPI-7", to: "KB5YZB-7", text: "RR(3)",
                                      via: ["DRLNOD*"], messageType: .prompt)
        XCTAssertTrue(echo.isDigipeatEcho(localCallsign: "k0epi-7"),
                      "case must not affect echo detection")
        XCTAssertFalse(echo.isDigipeatEcho(localCallsign: "N0CALL"),
                       "another station's frames are never our echoes")

        let notYetRepeated = ConsoleLine.packet(from: "K0EPI-7", to: "KB5YZB-7", text: "RR(3)",
                                                via: ["DRLNOD"], messageType: .prompt)
        XCTAssertFalse(notYetRepeated.isDigipeatEcho(localCallsign: "K0EPI-7"),
                       "a via without the H-bit star is our own TX log, not a heard copy")
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
