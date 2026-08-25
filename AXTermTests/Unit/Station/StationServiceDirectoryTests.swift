//
//  StationServiceDirectoryTests.swift
//  AXTermTests
//

import XCTest
import GRDB
@testable import AXTerm

final class StationServiceDirectoryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> SQLiteStationServiceStore {
        let queue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.migrator.migrate(queue)
        return SQLiteStationServiceStore(dbQueue: queue)
    }

    private func entry(_ callsign: String,
                       _ service: StationServiceParser.Service,
                       confidence: StationServiceConfidence = .declared,
                       at time: Date? = nil,
                       times: Int = 1) -> StationServiceEntry {
        StationServiceEntry(
            callsign: callsign, service: service, alias: nil,
            confidence: confidence, firstHeard: time ?? t0,
            lastHeard: time ?? t0, timesHeard: times, sourceText: "test")
    }

    // MARK: - Durability

    func testAServiceRoundTrips() throws {
        let store = try makeStore()
        try store.record([entry("KB5YZB-1", .bbs)])
        XCTAssertEqual(try store.services(for: "KB5YZB-1").map(\.service), [.bbs])
    }

    func testRepetitionAccumulatesRatherThanOverwrites() throws {
        let store = try makeStore()
        try store.record([entry("KB5YZB-1", .bbs, at: t0)])
        try store.record([entry("KB5YZB-1", .bbs, at: t0.addingTimeInterval(600))])
        try store.record([entry("KB5YZB-1", .bbs, at: t0.addingTimeInterval(1200))])

        // An ID heard once could be a decode error; the same claim every ten
        // minutes for a week is the network describing itself reliably, and
        // only a running count tells those apart.
        let stored = try XCTUnwrap(try store.services(for: "KB5YZB-1").first)
        XCTAssertEqual(stored.timesHeard, 3)
        XCTAssertEqual(stored.firstHeard, t0)
        XCTAssertEqual(stored.lastHeard, t0.addingTimeInterval(1200))
    }

    func testFirstHeardSurvivesAnOutOfOrderArrival() throws {
        let store = try makeStore()
        try store.record([entry("KB5YZB-1", .bbs, at: t0.addingTimeInterval(600))])
        try store.record([entry("KB5YZB-1", .bbs, at: t0)])
        XCTAssertEqual(try store.services(for: "KB5YZB-1").first?.firstHeard, t0)
    }

    // MARK: - The two confidences

    func testDeclaredAndDemonstratedAreKeptApart() throws {
        let store = try makeStore()
        try store.record([
            entry("DRLNOD", .digipeater, confidence: .declared),
            entry("DRLNOD", .digipeater, confidence: .demonstrated),
        ])
        // A station can claim to digipeat and be misconfigured; it cannot
        // fake having repeated a frame that reached us. Both facts are worth
        // keeping, and they are different facts.
        let stored = try store.services(for: "DRLNOD")
        XCTAssertEqual(Set(stored.map(\.confidence)), [.declared, .demonstrated])
    }

    func testServicesAreScopedToTheirStation() throws {
        let store = try makeStore()
        try store.record([entry("KB5YZB-1", .bbs)])
        XCTAssertTrue(try store.services(for: "K0NTS-1").isEmpty)
    }

    func testCallsignLookupIgnoresCase() throws {
        let store = try makeStore()
        try store.record([entry("kb5yzb-1", .bbs)])
        XCTAssertFalse(try store.services(for: "KB5YZB-1").isEmpty)
    }

    // MARK: - Harvesting from frames

    private func packet(from: String, to: String, text: String,
                        via: [AX25Address] = []) -> Packet {
        Packet(
            timestamp: t0,
            from: AX25Address(call: from.components(separatedBy: "-").first ?? from,
                              ssid: Int(from.components(separatedBy: "-").dropFirst().first ?? "") ?? 0),
            to: AX25Address(call: to, ssid: 0),
            via: via,
            frameType: .ui,
            infoText: text)
    }

    func testDeclarationsAreHarvestedFromIDFrames() {
        let entries = StationServiceHarvester.declarations(in: [
            packet(from: "KB5YZB-7", to: "ID",
                   text: "KB5YZB/R YZBBPQ/D KB5YZB-1/B KB5YZB-7/N"),
        ])
        XCTAssertTrue(entries.contains { $0.callsign == "KB5YZB-1" && $0.service == .bbs })
        XCTAssertTrue(entries.allSatisfy { $0.confidence == .declared })
    }

    func testOrdinaryTrafficYieldsNoDeclarations() {
        // Only ID/BEACON/NODES destinations are inspected; a connected-mode
        // exchange that happens to contain a slash is not an announcement.
        let entries = StationServiceHarvester.declarations(in: [
            packet(from: "K0NTS-1", to: "N3HYM-15", text: "CTN BBS> A/B testing"),
        ])
        XCTAssertTrue(entries.isEmpty)
    }

    func testARepeatedHopIsDemonstratedEvidence() {
        let hop = AX25Address(call: "DRLNOD", ssid: 0, repeated: true)
        let entries = StationServiceHarvester.demonstratedDigipeaters(in: [
            packet(from: "KB5YZB-7", to: "ID", text: "hi", via: [hop]),
        ])
        XCTAssertEqual(entries.map(\.callsign), ["DRLNOD"])
        XCTAssertEqual(entries.first?.confidence, .demonstrated)
        XCTAssertEqual(entries.first?.service, .digipeater)
    }

    func testAnUnrepeatedHopIsNotEvidence() {
        // H=0 is a *request* to be digipeated — the frame on its way to the
        // digi. Counting it would credit stations that never repeated
        // anything.
        let hop = AX25Address(call: "DRLNOD", ssid: 0, repeated: false)
        let entries = StationServiceHarvester.demonstratedDigipeaters(in: [
            packet(from: "KB5YZB-7", to: "ID", text: "hi", via: [hop]),
        ])
        XCTAssertTrue(entries.isEmpty)
    }

    func testServiceEndpointsAreNeverCreditedAsDigipeaters() {
        let hop = AX25Address(call: "WIDE1", ssid: 1, repeated: true)
        let entries = StationServiceHarvester.demonstratedDigipeaters(in: [
            packet(from: "KB5YZB-7", to: "ID", text: "hi", via: [hop]),
        ])
        XCTAssertTrue(entries.isEmpty, "WIDE1-1 is a routing convention, not a station")
    }

    // MARK: - Roles

    func testADeclaredBBSEarnsTheRole() {
        let declaration = StationServiceParser.Declaration(
            callsign: "KB5YZB-1", service: .bbs, alias: nil, sourceText: "test")
        let profile = NodeProfile.make(callsign: "KB5YZB-1",
                                       declaredServices: [declaration])
        XCTAssertTrue(profile.roles.contains(.bulletinBoard))
    }

    func testADeclaredNodeEarnsTheNetRomRoleWithoutABroadcast() {
        // The whole point: this network never sends NODES broadcasts, but its
        // nodes say what they are in every ID frame.
        let declaration = StationServiceParser.Declaration(
            callsign: "KB5YZB-7", service: .node, alias: nil, sourceText: "test")
        let profile = NodeProfile.make(callsign: "KB5YZB-7",
                                       declaredServices: [declaration])
        XCTAssertTrue(profile.roles.contains(.netromNode))
    }

    func testDeclarationsForOtherStationsAreNotAppliedHere() {
        let other = StationServiceParser.Declaration(
            callsign: "K0NTS-1", service: .bbs, alias: nil, sourceText: "test")
        let profile = NodeProfile.make(callsign: "KB5YZB-1", declaredServices: [other])
        XCTAssertFalse(profile.roles.contains(.bulletinBoard))
        XCTAssertTrue(profile.declaredServices.isEmpty)
    }
}
