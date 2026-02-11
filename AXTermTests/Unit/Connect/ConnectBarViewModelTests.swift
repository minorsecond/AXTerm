import XCTest
@testable import AXTerm

final class ConnectBarViewModelTests: XCTestCase {
    private static var retainedModels: [ConnectBarViewModel] = []

    private func makeViewModel() -> ConnectBarViewModel {
        let vm = ConnectBarViewModel()
        Self.retainedModels.append(vm)
        return vm
    }

    private func waitForSuggestions() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
    func testDigipeaterParserHandlesSpacesAndCommas() {
        let parsed = DigipeaterListParser.parse("DIGI1 DIGI2,DIGI3")
        XCTAssertEqual(parsed, ["DIGI1", "DIGI2", "DIGI3"])
    }

    func testCallsignValidationRejectsInvalidSSID() {
        XCTAssertTrue(ConnectCallsign.isValidSSIDCall("N0CALL-7"))
        XCTAssertFalse(ConnectCallsign.isValidSSIDCall("BAD-99"))
    }

    func testRoutePrefillDirectUsesHeardAsWhenDifferent() {
        let target = ConnectPrefillLogic.ax25DirectTarget(destination: "AA0QC", heardAs: "W0TX-7")
        XCTAssertEqual(target.to, "W0TX-7")
        XCTAssertEqual(target.note, "Heard as: W0TX-7")
    }

    func testContextDefaultModeSelectsRoutesAsNetRom() {
        XCTAssertEqual(ConnectBarMode.defaultMode(for: .routes), .netrom)
        XCTAssertEqual(ConnectBarMode.defaultMode(for: .stations), .ax25)
    }

    func testConnectCoordinatorRequestsNavigationOnConnectIntent() {
        let intent = ConnectIntent(
            kind: .ax25Direct,
            to: "N0CALL",
            sourceContext: .stations,
            suggestedRoutePreview: nil,
            validationErrors: [],
            routeHint: nil,
            note: nil
        )
        let request = ConnectRequest(intent: intent, mode: .ax25, executeImmediately: true)
        XCTAssertTrue(ConnectPrefillLogic.shouldNavigateOnConnect(request))

        let noNav = ConnectRequest(intent: intent, mode: .ax25, executeImmediately: false)
        XCTAssertFalse(ConnectPrefillLogic.shouldNavigateOnConnect(noNav))
    }

    func testFallbackDigipeatersUseRoutePathWithoutDestinationTail() {
        let hint = NetRomRouteHint(
            nextHop: "DRL",
            heardAs: "DRL",
            path: ["DRL", "KB5YZB-7"],
            hops: 2
        )
        let digis = ConnectPrefillLogic.fallbackDigipeaters(
            destination: "KB5YZB-7",
            hint: hint,
            nextHopOverride: nil
        )
        XCTAssertEqual(digis, ["DRL"])
    }

    func testDigipeaterValidationAllowsRoutingAlias() {
        XCTAssertTrue(CallsignValidator.isValidDigipeaterAddress("DRLNOD"))
        XCTAssertTrue(CallsignValidator.isValidDigipeaterAddress("DRLNOD-1"))
        XCTAssertFalse(CallsignValidator.isValidDigipeaterAddress("DRLNOD-99"))
    }

    func testDigipeaterValidationRejectsHopChainSyntax() {
        XCTAssertFalse(CallsignValidator.isValidDigipeaterAddress("A->B->C"))
    }

    func testNetRomPrefillIncludesRouteAndNeighborCandidates() async {
        let vm = makeViewModel()
        let hint = NetRomRouteHint(
            nextHop: "DRLNOD",
            heardAs: "DRL",
            path: ["DRLNOD", "KB5YZB-7"],
            hops: 2
        )
        vm.updateRuntimeData(
            stations: [],
            neighbors: [NeighborInfo(call: "NBR1", quality: 190, lastSeen: Date(), sourceType: "classic")],
            routes: [RouteInfo(destination: "KB5YZB-7", origin: "DRLNOD", quality: 220, path: ["DRLNOD", "KB5YZB-7"], lastUpdated: Date(), sourceType: "classic")],
            packets: [],
            favorites: []
        )
        vm.applyNetRomPrefill(destination: "KB5YZB-7", routeHint: hint, suggestedPreview: "DRLNOD -> KB5YZB-7 (2 hops)", nextHopOverride: nil)
        await waitForSuggestions()

        XCTAssertEqual(vm.mode, .netrom)
        XCTAssertTrue(vm.routePreview.contains("KB5YZB-7"))
        XCTAssertTrue(vm.nextHopOptions.contains(ConnectBarViewModel.autoNextHopID))
        XCTAssertTrue(vm.nextHopOptions.contains("DRLNOD"))
        XCTAssertTrue(vm.nextHopOptions.contains("NBR1"))
    }

    func testNetRomOverrideWarnsWhenUnknownForDestination() async {
        let vm = makeViewModel()
        let hint = NetRomRouteHint(
            nextHop: "DRLNOD",
            heardAs: nil,
            path: ["DRLNOD", "N0HI-7"],
            hops: 2
        )
        vm.updateRuntimeData(
            stations: [],
            neighbors: [NeighborInfo(call: "NBR1", quality: 190, lastSeen: Date(), sourceType: "classic")],
            routes: [RouteInfo(destination: "N0HI-7", origin: "DRLNOD", quality: 220, path: ["DRLNOD", "N0HI-7"], lastUpdated: Date(), sourceType: "classic")],
            packets: [],
            favorites: []
        )
        vm.applyNetRomPrefill(destination: "N0HI-7", routeHint: hint, suggestedPreview: nil, nextHopOverride: "NBR1")
        await waitForSuggestions()

        XCTAssertEqual(vm.routeOverrideWarning, "No known route via NBR1 — attempt may fail.")
    }

    func testContextModePersistence() {
        let vm = makeViewModel()
        vm.setMode(.netrom, for: .routes)
        vm.setMode(.ax25ViaDigi, for: .terminal)
        vm.applyContext(.routes)
        XCTAssertEqual(vm.mode, .netrom)
        vm.applyContext(.terminal)
        XCTAssertEqual(vm.mode, .ax25ViaDigi)
    }

    func testAutoAttemptStatusLifecycle() {
        let vm = makeViewModel()
        vm.beginAutoAttempting()
        XCTAssertTrue(vm.isAutoAttemptInProgress)
        vm.updateAutoAttemptStatus("Trying 1/3: via DRL")
        XCTAssertEqual(vm.autoAttemptStatus, "Trying 1/3: via DRL")
        vm.endAutoAttempting()
        XCTAssertFalse(vm.isAutoAttemptInProgress)
        XCTAssertNil(vm.autoAttemptStatus)
    }

    func testCallsignNormalizationPreservesHyphenDuringTyping() {
        let vm = makeViewModel()
        vm.applySuggestedTo("kb5yzb-7")
        XCTAssertEqual(vm.toCall, "KB5YZB-7", "applySuggestedTo should preserve hyphen (trim+uppercase only)")
    }

    func testBuildIntentUsesCurrentRoutingMode() {
        let vm = makeViewModel()
        vm.setMode(.netrom, for: .terminal)
        vm.applySuggestedTo("KB5YZB-7")
        let intent = vm.buildIntent(sourceContext: .terminal)
        switch intent.kind {
        case .netrom:
            break // expected
        default:
            XCTFail("Expected .netrom kind but got \(intent.kind)")
        }
    }

    func testAdaptiveTelemetryLabelUpdates() {
        let vm = makeViewModel()
        let t1 = AdaptiveTelemetry(k: 2, p: 128, n2: 2, rtoSeconds: 3.0, qualityLabel: "Good")
        vm.setAdaptiveTelemetry(t1)
        XCTAssertEqual(vm.adaptiveTelemetry?.compactLabel, "K2 P128 N2 2")

        let t2 = AdaptiveTelemetry(k: 1, p: 64, n2: 4, rtoSeconds: 5.0, qualityLabel: "Degraded")
        vm.setAdaptiveTelemetry(t2)
        XCTAssertEqual(vm.adaptiveTelemetry?.compactLabel, "K1 P64 N2 4")
    }

}
