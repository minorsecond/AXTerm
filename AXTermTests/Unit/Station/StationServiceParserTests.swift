//
//  StationServiceParserTests.swift
//  AXTermTests
//
//  Most networks have no NET/ROM NODES broadcast to listen for, but nodes,
//  BBSs and digipeaters identify themselves anyway — the ID frame is a licence
//  requirement and operators fill it with a service list. Every example below
//  is a real frame from the Denver-area network.
//

import XCTest
@testable import AXTerm

final class StationServiceParserTests: XCTestCase {

    private func services(_ declarations: [StationServiceParser.Declaration],
                          for callsign: String) -> Set<StationServiceParser.Service> {
        Set(declarations.filter { $0.callsign == callsign }.map(\.service))
    }

    // MARK: - The tokens that used to be discarded

    func testCallsignFormDeclaresThatCallsignsService() {
        // NodeAliasParser skips these because a callsign is not an alias —
        // which is right for alias resolution and threw away the two most
        // direct declarations in the frame.
        let declarations = StationServiceParser.parse(
            "KB5YZB/R YZBBPQ/D KB5YZB-1/B KB5YZB-7/N", source: "KB5YZB-7")

        XCTAssertEqual(services(declarations, for: "KB5YZB-1"), [.bbs])
        // KB5YZB-7 declares itself a node by callsign, and also owns the
        // alias-form digipeater token `YZBBPQ/D` — one station running two
        // services, which is exactly what the frame says.
        XCTAssertTrue(services(declarations, for: "KB5YZB-7").contains(.node))
        XCTAssertTrue(services(declarations, for: "KB5YZB-7").contains(.digipeater))
        XCTAssertEqual(
            declarations.first { $0.alias == "YZBBPQ" }?.service, .digipeater)
    }

    func testAliasFormBelongsToTheSender() {
        let declarations = StationServiceParser.parse(
            "KE0NCQ/R DRL/D DRLBBS/B DRLNOD/N", source: "KE0NCQ")

        // DRL, DRLBBS and DRLNOD are tactical names for services KE0NCQ runs.
        let byAlias = Dictionary(uniqueKeysWithValues:
            declarations.compactMap { d in d.alias.map { ($0, d) } })
        XCTAssertEqual(byAlias["DRLNOD"]?.service, .node)
        XCTAssertEqual(byAlias["DRLBBS"]?.service, .bbs)
        XCTAssertEqual(byAlias["DRL"]?.service, .digipeater)
        XCTAssertEqual(byAlias["DRLNOD"]?.callsign, "KE0NCQ")
    }

    func testTheSendersOwnRelayTokenIsKept() {
        let declarations = StationServiceParser.parse("KE0NCQ/R DRL/D", source: "KE0NCQ")
        XCTAssertTrue(services(declarations, for: "KE0NCQ").contains(.relay))
    }

    // MARK: - Prose beacons

    func testTheProseFormIsReadToo() {
        // Operators write beacons for humans. A directory built only from the
        // slash form would miss stations announcing loudly in words.
        let declarations = StationServiceParser.parse(
            "Denver Water Amateur Radio Club (DWARC) - Digipeat Alias = DWARC; Node:KD0SSP-7; PBBS:KD0SSP-1",
            source: "KD0SSP")

        XCTAssertEqual(services(declarations, for: "KD0SSP-7"), [.node])
        XCTAssertEqual(services(declarations, for: "KD0SSP-1"), [.bbs])
    }

    func testAnRMSLabelDeclaresAGateway() {
        let declarations = StationServiceParser.parse("RMS:K0NTS-10", source: "K0NTS-7")
        XCTAssertEqual(services(declarations, for: "K0NTS-10"), [.gateway])
    }

    // MARK: - Restraint

    func testProseWithNoDeclarationYieldsNothing() {
        // "Connect to K0NTS-1 & K0NTS-10" names callsigns without saying what
        // they are. Guessing "BBS" from an invitation would be inference
        // dressed as a declaration.
        let declarations = StationServiceParser.parse(
            "Colorado Traffic Net BBS & RMS.  Connect to K0NTS-1 & K0NTS-10",
            source: "K0NTS-7")
        XCTAssertTrue(declarations.isEmpty)
    }

    func testUnknownServiceLettersAreIgnored() {
        let declarations = StationServiceParser.parse("THING/Z", source: "K0EPI-7")
        XCTAssertTrue(declarations.isEmpty, "a letter we cannot interpret is not a service")
    }

    func testOrdinaryProseIsNotMinedForSlashes() {
        let declarations = StationServiceParser.parse(
            "Greetings from the KF0HEG Commodore 128 PBBS. Stop by and say hi",
            source: "KF0HEG")
        XCTAssertTrue(declarations.isEmpty)
    }

    func testDuplicateTokensDeclareOnce() {
        let declarations = StationServiceParser.parse(
            "KB5YZB-1/B KB5YZB-1/B", source: "KB5YZB-7")
        XCTAssertEqual(declarations.filter { $0.callsign == "KB5YZB-1" }.count, 1)
    }

    func testTheSourceTextIsKeptSoTheClaimCanBeChecked() {
        let text = "KB5YZB/R YZBBPQ/D KB5YZB-1/B KB5YZB-7/N"
        let declarations = StationServiceParser.parse(text, source: "KB5YZB-7")
        XCTAssertTrue(declarations.allSatisfy { $0.sourceText == text })
    }

    func testEveryServiceHasALabel() {
        for service in StationServiceParser.Service.allCases {
            XCTAssertFalse(service.label.isEmpty)
        }
    }
}
