import Foundation
import Testing
@testable import AXTerm

struct NetworkGraphBuilderTests {
    @Test
    func minEdgeCountFiltersEdgesAndNodes() {
        let base = Date(timeIntervalSince1970: 1_700_100_000)
        let packets = [
            makePacket(timestamp: base, from: "ALPHA", to: "BRAVO"),
            makePacket(timestamp: base.addingTimeInterval(1), from: "ALPHA", to: "BRAVO"),
            makePacket(timestamp: base.addingTimeInterval(2), from: "ALPHA", to: "CHARLIE")
        ]

        let model = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(includeViaDigipeaters: false, minimumEdgeCount: 2, maxNodes: 10)
        )

        #expect(model.edges.count == 1)
        #expect(model.nodes.count == 2)
        #expect(model.nodes.map { $0.id }.sorted() == ["ALPHA", "BRAVO"])
    }

    @Test
    func includeViaDigipeatersAddsNodesAndEdges() {
        let base = Date(timeIntervalSince1970: 1_700_110_000)
        let packets = [
            makePacket(timestamp: base, from: "ALPHA", to: "BRAVO", via: ["DIGI"]) 
        ]

        let modelWithoutVia = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(includeViaDigipeaters: false, minimumEdgeCount: 1, maxNodes: 10)
        )

        let modelWithVia = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(includeViaDigipeaters: true, minimumEdgeCount: 1, maxNodes: 10)
        )

        #expect(modelWithoutVia.nodes.count == 2)
        #expect(modelWithVia.nodes.count == 3)
        #expect(modelWithVia.edges.count == 2)
    }

    @Test
    func stableNodeIDsAcrossRebuilds() {
        let base = Date(timeIntervalSince1970: 1_700_120_000)
        let packets = [
            makePacket(timestamp: base, from: "ALPHA", to: "BRAVO"),
            makePacket(timestamp: base.addingTimeInterval(5), from: "BRAVO", to: "CHARLIE")
        ]

        let options = NetworkGraphBuilder.Options(includeViaDigipeaters: false, minimumEdgeCount: 1, maxNodes: 10)
        let modelA = NetworkGraphBuilder.build(packets: packets, options: options)
        let modelB = NetworkGraphBuilder.build(packets: packets, options: options)

        #expect(modelA.nodes.map { $0.id }.sorted() == modelB.nodes.map { $0.id }.sorted())
    }

    @Test
    func maxNodesCappingDeterministic() {
        let base = Date(timeIntervalSince1970: 1_700_130_000)
        let packets = [
            makePacket(timestamp: base, from: "ALPHA", to: "BRAVO"),
            makePacket(timestamp: base.addingTimeInterval(1), from: "ALPHA", to: "BRAVO"),
            makePacket(timestamp: base.addingTimeInterval(2), from: "CHARLIE", to: "DELTA")
        ]

        let model = NetworkGraphBuilder.build(
            packets: packets,
            options: NetworkGraphBuilder.Options(includeViaDigipeaters: false, minimumEdgeCount: 1, maxNodes: 2)
        )

        #expect(model.nodes.count == 2)
        #expect(model.nodes.map { $0.id }.sorted().contains("ALPHA"))
        #expect(model.nodes.map { $0.id }.sorted().contains("BRAVO"))
        #expect(model.droppedNodesCount == 2)
    }

    private func makePacket(
        timestamp: Date,
        from: String,
        to: String,
        via: [String] = []
    ) -> Packet {
        Packet(
            timestamp: timestamp,
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: via.map { AX25Address(call: $0) },
            frameType: .ui,
            info: Data(repeating: 0x41, count: 10)
        )
    }
}
