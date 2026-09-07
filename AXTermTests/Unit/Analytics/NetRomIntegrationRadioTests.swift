import XCTest
@testable import AXTerm

/// Neighbours and routes learned through `NetRomIntegration` are attributed to
/// the radio that heard them, not silently collapsed onto the primary — the
/// prerequisite for the Neighbors/Routes page to scope by radio.
@MainActor
final class NetRomIntegrationRadioTests: XCTestCase {

    private let local = "K0EPI"
    private let uhf = RadioID(rawValue: "uhf")

    private func makeIntegration() -> NetRomIntegration {
        NetRomIntegration(
            localCallsign: local, mode: .hybrid,
            routerConfig: NetRomConfig.default,
            inferenceConfig: NetRomInferenceConfig(
                evidenceWindowSeconds: 60, inferredRouteHalfLifeSeconds: 30,
                inferredBaseQuality: 120, reinforcementIncrement: 20,
                inferredMinimumQuality: 50, maxInferredRoutesPerDestination: 5,
                dataProgressWeight: 1.0, routingBroadcastWeight: 0.8,
                uiBeaconWeight: 0.4, ackOnlyWeight: 0.1, retryPenaltyMultiplier: 0.7),
            linkConfig: LinkQualityConfig.default)
    }

    private func directPacket(from: String, radio: RadioID?, at: Date) -> Packet {
        Packet(timestamp: at, from: AX25Address(call: from), to: AX25Address(call: local),
               via: [], frameType: .ui, control: 0x03, info: Data("HI".utf8),
               rawAx25: Data([0x01]), radioID: radio)
    }

    func testADirectlyHeardNeighbourIsAttributedToTheRadioThatHeardIt() {
        let integration = makeIntegration()
        let t = Date(timeIntervalSince1970: 1_700_002_000)
        integration.observePacket(directPacket(from: "W0ABC", radio: .primary, at: t), timestamp: t)
        integration.observePacket(directPacket(from: "W0UHF", radio: uhf, at: t.addingTimeInterval(1)),
                                  timestamp: t.addingTimeInterval(1))

        let neighbors = integration.currentNeighbors()
        let uhfNeighbor = neighbors.first { $0.call == "W0UHF" }
        let primaryNeighbor = neighbors.first { $0.call == "W0ABC" }
        XCTAssertEqual(uhfNeighbor?.radioID, uhf, "heard on UHF, attributed to UHF — not the primary")
        XCTAssertEqual(primaryNeighbor?.radioID, .primary)
    }

    func testTheSameStationHeardOnTwoRadiosIsTwoNeighbours() {
        let integration = makeIntegration()
        let t = Date(timeIntervalSince1970: 1_700_002_000)
        integration.observePacket(directPacket(from: "W0DUAL", radio: .primary, at: t), timestamp: t)
        integration.observePacket(directPacket(from: "W0DUAL", radio: uhf, at: t.addingTimeInterval(1)),
                                  timestamp: t.addingTimeInterval(1))

        let dual = integration.currentNeighbors().filter { $0.call == "W0DUAL" }
        XCTAssertEqual(Set(dual.map(\.radioID)), [.primary, uhf],
                       "a station on two radios is a neighbour on each — different antenna, different path")
    }

    /// An inferred route from a digipeated frame carries the radio that heard
    /// the frame, so a route via a UHF digipeater is not filed under the primary.
    func testAnInferredRouteCarriesTheRadioThatHeardIt() {
        let integration = makeIntegration()
        let t = Date(timeIntervalSince1970: 1_700_002_000)
        // Third-party W0FAR heard via a repeated digipeater W0DIGI, on UHF.
        func digipeated(_ offset: TimeInterval) -> Packet {
            Packet(timestamp: t.addingTimeInterval(offset),
                   from: AX25Address(call: "W0FAR"), to: AX25Address(call: "CQ"),
                   via: [AX25Address(call: "W0DIGI", repeated: true)],
                   frameType: .ui, control: 0x03, info: Data("DATA".utf8),
                   rawAx25: Data([0x01]), radioID: uhf)
        }
        for i in 0..<3 { integration.observePacket(digipeated(Double(i)), timestamp: t.addingTimeInterval(Double(i))) }

        let farRoutes = integration.currentRoutes().filter { $0.destination == "W0FAR" }
        XCTAssertFalse(farRoutes.isEmpty, "a digipeated frame should infer a route")
        XCTAssertTrue(farRoutes.allSatisfy { $0.radioID == uhf },
                      "the inferred route is a way in on the radio that heard it")
    }
}
