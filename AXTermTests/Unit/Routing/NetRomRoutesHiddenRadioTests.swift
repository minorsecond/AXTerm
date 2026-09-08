import XCTest
@testable import AXTerm

/// The Neighbors/Routes page honours the radio filter, like the map, the
/// packets table and the analytics dashboard: a hidden radio's neighbours are
/// not shown, while a station heard on a visible radio stays.
@MainActor
final class NetRomRoutesHiddenRadioTests: XCTestCase {

    private let local = "K0EPI"
    private let uhf = RadioID(rawValue: "uhf")

    private func directPacket(from: String, radio: RadioID?, at: Date) -> Packet {
        Packet(timestamp: at, from: AX25Address(call: from), to: AX25Address(call: local),
               via: [], frameType: .ui, control: 0x03, info: Data("HI".utf8),
               rawAx25: Data([0x01]), radioID: radio)
    }

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

    func testAHiddenRadiosNeighboursAreNotShown() {
        let integration = makeIntegration()
        let t = Date(timeIntervalSince1970: 1_700_002_000)
        integration.observePacket(directPacket(from: "W0ABC", radio: .primary, at: t), timestamp: t)
        integration.observePacket(directPacket(from: "W0UHF", radio: uhf, at: t.addingTimeInterval(1)),
                                  timestamp: t.addingTimeInterval(1))

        let engine = PacketEngine(settings: AppSettingsStore(
            defaults: UserDefaults(suiteName: "NetRomRoutesHidden.\(UUID().uuidString)")!))
        // PacketEngine loads hiddenRadioIDs from UserDefaults.standard, which a
        // prior run may have left non-empty; start from a known-clean baseline.
        engine.hiddenRadioIDs = []
        let viewModel = NetRomRoutesViewModel(
            integration: integration, packetEngine: engine, settings: nil)

        viewModel.refresh()
        XCTAssertEqual(Set(viewModel.neighbors.map(\.callsign)), ["W0ABC", "W0UHF"],
                       "both visible with nothing hidden")

        engine.hiddenRadioIDs = [uhf]
        viewModel.refresh()
        let shown = Set(viewModel.neighbors.map(\.callsign))
        XCTAssertTrue(shown.contains("W0ABC"))
        XCTAssertFalse(shown.contains("W0UHF"), "hidden radio's neighbour is excluded")
    }
}
