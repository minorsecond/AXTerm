//
//  GraphInspectorBothEndsTests.swift
//  AXTermTests
//
//  On A (705), after sending B (ID-50) a 20 KB file, the inspector for B's
//  node read "Packets In 0" and "No neighbors found" with an edge drawn to it
//  (smoke run 2026-10-03-1, issue 95). The graph is built from heard frames
//  only, so our 176 I-frames never counted, and a one-way relationship was
//  recorded only on the station that did the hearing.
//

import XCTest
@testable import AXTerm

final class GraphInspectorBothEndsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_400_000)

    private func frame(from: (String, Int), to: (String, Int), at seconds: Double,
                       type: FrameType = .i, bytes: Int = 128) -> Packet {
        Packet(timestamp: t0.addingTimeInterval(seconds),
               from: AX25Address(call: from.0, ssid: from.1),
               to: AX25Address(call: to.0, ssid: to.1),
               frameType: type, control: type == .i ? 0x00 : 0x01,
               info: Data(count: type == .i ? bytes : 0), rawAx25: Data())
    }

    func testOurOwnTransmissionsCountTowardThePeersTraffic() throws {
        let sent = (0..<176).map { frame(from: ("K0EPI", 2), to: ("K0EPI", 3), at: Double($0) * 2) }
        let heard = (0..<88).map {
            frame(from: ("K0EPI", 3), to: ("K0EPI", 2), at: Double($0) * 4 + 1, type: .s)
        }
        let traffic = AnalyticsDashboardViewModel.nodeTraffic(
            heard: heard, transmitted: sent, identityMode: .ssid)

        let peer = try XCTUnwrap(traffic["K0EPI-3"])
        XCTAssertEqual(peer.inCount, 176, "every I-frame we sent it")
        XCTAssertEqual(peer.inBytes, 176 * 128)
        XCTAssertEqual(peer.outCount, 88, "every RR we heard from it")
        let me = try XCTUnwrap(traffic["K0EPI-2"])
        XCTAssertEqual(me.outCount, 176)
        XCTAssertEqual(me.inCount, 88)
    }

    func testTheGraphStillBuildsFromHeardFramesOnly() {
        let heard = (0..<10).map {
            frame(from: ("K0EPI", 3), to: ("K0EPI", 2), at: Double($0) * 30, type: .s)
        }
        let graph = NetworkGraphBuilder.buildClassified(
            packets: heard,
            options: .init(includeViaDigipeaters: false, minimumEdgeCount: 1, maxNodes: 100,
                           stationIdentityMode: .ssid),
            now: t0.addingTimeInterval(600))
        XCTAssertFalse(graph.edges.contains { $0.linkType == .directPeer },
                       "a link we only heard one side of is not shown as a two-way exchange")
    }

    /// The station that was heard lists who heard it, and the hearer's own
    /// list is unchanged.
    func testBothEndsOfAOneWayEdgeNameEachOther() throws {
        var builder = GraphFixtureBuilder(baseTimestamp: t0)
        _ = builder.addSustainedDirectActivity(from: "W5NTS-10", to: "K0EPI-7",
                                               minuteSpan: 5, packetsPerMinute: 2)
        let graph = NetworkGraphBuilder.buildClassified(
            packets: builder.buildPackets(),
            options: .init(includeViaDigipeaters: false, minimumEdgeCount: 1, maxNodes: 100,
                           stationIdentityMode: .ssid),
            now: t0.addingTimeInterval(600))
        XCTAssertTrue(graph.edges.contains { $0.linkType == .heardDirect })

        let hearer = graph.relationships(for: "K0EPI-7")
        XCTAssertEqual(hearer.map(\.id), ["W5NTS-10"])
        XCTAssertFalse(try XCTUnwrap(hearer.first).isHeardBy)

        let heard = graph.relationships(for: "W5NTS-10")
        XCTAssertEqual(heard.map(\.id), ["K0EPI-7"])
        let back = try XCTUnwrap(heard.first)
        XCTAssertTrue(back.isHeardBy)
        XCTAssertEqual(back.linkType, .heardDirect)
    }
}
