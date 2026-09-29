//
//  TerminalSessionLineFilterTests.swift
//  AXTermTests
//

import XCTest
@testable import AXTerm

final class TerminalSessionLineFilterTests: XCTestCase {
    func testApplyWithoutPeerReturnsAllLines() {
        let lines = sampleLines()

        let filtered = TerminalSessionLineFilter.apply(lines, peer: nil)

        XCTAssertEqual(filtered.count, lines.count)
    }

    func testApplyWithPeerFiltersToMatchingFromAndTo() {
        let lines = sampleLines()

        let filtered = TerminalSessionLineFilter.apply(lines, peer: "PEER1")

        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.allSatisfy { line in
            (line.from?.contains("PEER1") == true) || (line.to?.contains("PEER1") == true)
        })
    }

    private func sampleLines() -> [ConsoleLine] {
        [
            .packet(from: "PEER1", to: "ME", text: "hello"),
            .packet(from: "OTHER", to: "ME", text: "beacon"),
            .packet(from: "ME", to: "PEER1", text: "reply")
        ]
    }
}
