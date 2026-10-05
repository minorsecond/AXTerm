//
//  NodesBroadcastSemanticsTests.swift
//  AXTermTests
//
//  What a NODES broadcast teaches the station that hears it.
//
//  Smoke run 2026-10-03-1, issue 38: each AXTerm station listed itself as
//  its only entry, and a station hearing that did not make the sender a
//  destination, so the node shell's NODES said "No nodes known yet" with
//  EPINDA just heard. Aliases from NODES never reached the Nodes page.
//  Classic NET/ROM: the sender is a destination, reached directly at the
//  link's quality, and the header carries its alias.
//

import XCTest
@testable import AXTerm

@MainActor
final class NodesBroadcastSemanticsTests: XCTestCase {

    private let heardAt = Date(timeIntervalSince1970: 1_791_000_000)

    override func setUp() {
        super.setUp()
        CallsignValidator.configureIgnoredServiceEndpoints([])
    }

    private func nodes(from call: String, ssid: Int, payload: [UInt8]) -> Packet {
        Packet(timestamp: heardAt,
               from: AX25Address(call: call, ssid: ssid),
               to: AX25Address(call: "NODES"),
               frameType: .ui, control: 0x03, pid: NetRomBroadcastParser.netromPID,
               info: Data(payload), rawAx25: Data([0x01]))
    }

    /// What a station with forwarding off now sends: the header alone.
    private var headerOnlyFromB: Packet {
        nodes(from: "K0EPI", ssid: 3, payload: [0xFF] + Array("EPINDB".utf8))
    }

    /// One a forwarding node sends: its alias, then COSCO (KE0GB-7) via itself.
    private var withAnEntryFromDRL: Packet {
        let entry = NetRomNodesBroadcast.Entry(
            destination: AX25Address(call: "KE0GB", ssid: 7), alias: "COSCO",
            bestNeighbor: AX25Address(call: "KE0NCQ", ssid: 0), quality: 200)
        let payload = NetRomNodesBroadcast.encode(originAlias: "DRLNOD", entries: [entry])[0]
        return nodes(from: "KE0NCQ", ssid: 0, payload: Array(payload))
    }

    func testAHeaderOnlyBroadcastParsesWithItsAlias() throws {
        let result = try XCTUnwrap(NetRomBroadcastParser.parse(packet: headerOnlyFromB))
        XCTAssertEqual(result.originCallsign, "K0EPI-3")
        XCTAssertEqual(result.originAlias, "EPINDB")
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testAHeaderWithAnUnprintableAliasIsNotABroadcast() {
        XCTAssertNil(NetRomBroadcastParser.parse(
            packet: nodes(from: "K0EPI", ssid: 3, payload: [0xFF, 0x96, 0x60, 0x8A, 0xA0, 0x92, 0x40])))
    }

    func testTheSenderBecomesADestinationAtTheLinkQuality() throws {
        let integration = NetRomIntegration(localCallsign: "K0EPI-2", mode: .classic)
        integration.observePacket(headerOnlyFromB, timestamp: heardAt)

        let neighbor = try XCTUnwrap(integration.currentNeighbors().first { $0.call == "K0EPI-3" })
        let route = try XCTUnwrap(integration.currentRoutes().first { $0.destination == "K0EPI-3" },
                                  "the node shell's NODES lists routes, and the sender is one")
        XCTAssertEqual(route.origin, "K0EPI-3")
        XCTAssertEqual(route.quality, neighbor.quality)
        XCTAssertEqual(route.path, ["K0EPI-3"])
    }

    func testEntriesStillBecomeRoutesThroughTheSender() {
        let integration = NetRomIntegration(localCallsign: "K0EPI-2", mode: .classic)
        integration.observePacket(withAnEntryFromDRL, timestamp: heardAt)
        let destinations = Set(integration.currentRoutes().map(\.destination))
        XCTAssertTrue(destinations.isSuperset(of: ["KE0NCQ", "KE0GB-7"]), "\(destinations)")
    }

    func testTheNodesPageLearnsAliasesFromNODES() {
        let suite = "NodesBroadcastSemanticsTests-\(UUID().uuidString)"
        let store = NodeAliasStore(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        store.ingest(packets: [headerOnlyFromB, withAnEntryFromDRL])

        XCTAssertEqual(store.directory.callsign(for: "EPINDB"), "K0EPI-3")
        XCTAssertEqual(store.directory.callsign(for: "DRLNOD"), "KE0NCQ")
        XCTAssertEqual(store.directory.callsign(for: "COSCO"), "KE0GB-7")
    }

    /// A node heard announcing itself is reachable directly. With no self
    /// entry in NODES (issue 38) nothing lists it, and the Nodes page filed
    /// EPINDB under "No route known" while Routes had the route (smoke run
    /// 2026-10-03-1, issue 65).
    func testANodeHeardAnnouncingItselfIsReachableDirectly() throws {
        let suite = "NodesBroadcastSemanticsTests-\(UUID().uuidString)"
        let store = NodeAliasStore(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        store.ingest(packets: [headerOnlyFromB])
        let entry = try XCTUnwrap(store.directory.entry(for: "EPINDB"))
        XCTAssertTrue(entry.tellers.isEmpty, "a node listing itself is still no teller")
        XCTAssertNotNil(entry.heardDirectlyAt)
        XCTAssertTrue(entry.isReachable)
    }

    func testHeardDirectlySurvivesSavingAndLoading() throws {
        var directory = NodeAliasDirectory()
        directory.record(NodeAliasParser.Announcement(alias: "EPINDB", callsign: "K0EPI-3", service: "N"),
                         at: Date(timeIntervalSince1970: 1000))
        directory.noteHeardDirectly(alias: "EPINDB", at: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(directory.entry(for: "EPINDB"))
        let back = try JSONDecoder().decode(NodeAliasDirectory.Entry.self, from: data)
        XCTAssertEqual(back.heardDirectlyAt, Date(timeIntervalSince1970: 1000))
    }
}
