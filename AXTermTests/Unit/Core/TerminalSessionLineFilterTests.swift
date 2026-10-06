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

    /// A session's notices often name the station by its node alias. The
    /// circuit to EPINDB filters on K0EPI-3, and its failure notice "EPINDB
    /// did not answer as a NET/ROM node" was hidden from the session that
    /// asked for it (smoke run 2026-10-03-1, issue 86).
    func testANoticeNamingTheStationsAliasStaysInItsSession() {
        let lines: [ConsoleLine] = [
            .packet(from: "K0EPI-2", to: "K0EPI-3", text: "SABM P"),
            .system("EPINDB did not answer as a NET/ROM node (no answer in 30s)."),
            .system("COSCO did not answer as a NET/ROM node."),
        ]
        let filtered = TerminalSessionLineFilter.apply(lines, peer: "K0EPI-3", aliases: ["EPINDB"])
        XCTAssertEqual(filtered.map(\.text), ["SABM P", "EPINDB did not answer as a NET/ROM node (no answer in 30s)."])
        XCTAssertEqual(TerminalSessionLineFilter.apply(lines, peer: "K0EPI-3").count, 1,
                       "without aliases, only the callsign matches")
    }

    private func sampleLines() -> [ConsoleLine] {
        [
            .packet(from: "PEER1", to: "ME", text: "hello"),
            .packet(from: "OTHER", to: "ME", text: "beacon"),
            .packet(from: "ME", to: "PEER1", text: "reply")
        ]
    }
}
