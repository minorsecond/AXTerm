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
        // Navigation follows *execution*, and only an explicit action may
        // execute — see ConnectOriginTests.
        let request = ConnectRequest(intent: intent, mode: .ax25,
                                     executeImmediately: true, origin: .explicitAction)
        XCTAssertTrue(ConnectPrefillLogic.shouldNavigateOnConnect(request))

        let noNav = ConnectRequest(intent: intent, mode: .ax25,
                                   executeImmediately: false, origin: .explicitAction)
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

    // MARK: - Auto-routing default + the visible routing switch

    /// Picking a station should just route the best way — Auto is the default
    /// everywhere except the Routes page, where the operator pointed at one route.
    func testDefaultAutoRoutingByContext() {
        XCTAssertTrue(ConnectBarMode.defaultAutoRouting(for: .stations))
        XCTAssertTrue(ConnectBarMode.defaultAutoRouting(for: .neighbors))
        XCTAssertTrue(ConnectBarMode.defaultAutoRouting(for: .terminal))
        XCTAssertFalse(ConnectBarMode.defaultAutoRouting(for: .routes))
    }

    func testApplyContextSeedsAutoRouting() {
        let vm = makeViewModel()
        vm.applyContext(.terminal)
        XCTAssertTrue(vm.autoRouting)
        XCTAssertEqual(vm.routingChoice, .auto)
        vm.applyContext(.routes)
        XCTAssertFalse(vm.autoRouting, "Routes page means a specific NET/ROM route")
        XCTAssertEqual(vm.routingChoice, .netrom)
    }

    func testRoutingChoiceMapsToModeAndAutoRouting() {
        let vm = makeViewModel()
        vm.applyContext(.terminal)

        vm.setRoutingChoice(.direct, for: .terminal)
        XCTAssertFalse(vm.autoRouting)
        XCTAssertEqual(vm.mode, .ax25)
        XCTAssertEqual(vm.routingChoice, .direct)

        vm.setRoutingChoice(.digi, for: .terminal)
        XCTAssertEqual(vm.mode, .ax25ViaDigi)
        XCTAssertEqual(vm.routingChoice, .digi)

        vm.setRoutingChoice(.netrom, for: .terminal)
        XCTAssertEqual(vm.mode, .netrom)
        XCTAssertEqual(vm.routingChoice, .netrom)

        vm.setRoutingChoice(.auto, for: .terminal)
        XCTAssertTrue(vm.autoRouting)
        XCTAssertEqual(vm.routingChoice, .auto)
    }

    func testForcedProtocolPersistsPerContext() {
        let vm = makeViewModel()
        vm.applyContext(.terminal)
        vm.setRoutingChoice(.direct, for: .terminal)   // force off Auto here
        vm.applyContext(.routes)                        // its own default
        vm.applyContext(.terminal)                      // return
        XCTAssertFalse(vm.autoRouting, "a forced protocol is remembered per context")
        XCTAssertEqual(vm.routingChoice, .direct)
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

    func testDestinationSelectionPersistsAfterValidation() {
        let vm = makeViewModel()
        vm.applySuggestedTo("KB5YZB-7")
        vm.validate()
        XCTAssertEqual(vm.toCall, "KB5YZB-7", "Destination should persist after validation")
    }

    func testSessionLifecycleStateTransitions() {
        let vm = makeViewModel()
        vm.applySuggestedTo("N0CALL")
        vm.enterConnectDraftMode()

        // disconnectedDraft → connecting
        vm.markConnecting()
        if case .connecting = vm.barState {} else {
            XCTFail("Expected .connecting but got \(vm.barState)")
        }

        // connecting → connected
        vm.markConnected(sourceCall: "MYCALL", destination: "N0CALL", via: [], transportMode: .ax25, forcedNextHop: nil)
        if case .connectedSession = vm.barState {} else {
            XCTFail("Expected .connectedSession but got \(vm.barState)")
        }

        // connected → disconnecting
        vm.markDisconnecting()
        if case .disconnecting = vm.barState {} else {
            XCTFail("Expected .disconnecting but got \(vm.barState)")
        }

        // disconnecting → disconnected
        vm.markDisconnected()
        if case .disconnectedDraft = vm.barState {} else {
            XCTFail("Expected .disconnectedDraft but got \(vm.barState)")
        }
    }

    func testCallsignWithSSIDPreservedOnSelection() {
        let vm = makeViewModel()

        // Test various SSIDs
        for ssid in 0...15 {
            let call = "N0CALL-\(ssid)"
            vm.applySuggestedTo(call)
            XCTAssertEqual(vm.toCall, call, "SSID -\(ssid) should be preserved")
        }
    }

    func testRoutingSummaryNoContradiction() {
        // When mode is ax25ViaDigi but path is empty, the summary must NOT say
        // "via Digi (Direct)" or any contradictory label. It should indicate Auto.
        let vm = makeViewModel()
        vm.setMode(.ax25ViaDigi, for: .terminal)
        vm.viaDigipeaters = []
        // The RoutingCapsuleButton's summaryText uses mode + viaDigipeaters.
        // Verify the raw state: mode is viaDigi, path is empty.
        XCTAssertEqual(vm.mode, .ax25ViaDigi)
        XCTAssertTrue(vm.viaDigipeaters.isEmpty, "Empty digi path should represent Auto mode")

        // With an explicit path it should show the path, not "Direct"
        vm.viaDigipeaters = ["DRL"]
        XCTAssertEqual(vm.viaDigipeaters, ["DRL"])
    }

    func testCallsignNormalizePreservesDash() {
        // Verify normalize does NOT strip dashes
        XCTAssertEqual(CallsignValidator.normalize("KB5YZB-7"), "KB5YZB-7")
        XCTAssertEqual(CallsignValidator.normalize("n0call-15"), "N0CALL-15")
        XCTAssertEqual(CallsignValidator.normalize(" w0tx-0 "), "W0TX-0")
    }

    func testDigiComparisonTreatsCaseAsDuplicate() {
        let duplicate = DigipeaterListParser.firstDuplicate(in: ["DRLNOD", "drlnod"], existing: [])
        XCTAssertEqual(duplicate, "DRLNOD")
    }

    func testDigiComparisonTreatsDashZeroAsDuplicate() {
        let duplicate = DigipeaterListParser.firstDuplicate(in: ["DRLNOD", "DRLNOD-0"], existing: [])
        XCTAssertEqual(duplicate, "DRLNOD-0")
    }

    func testDigiComparisonKeepsNonZeroSsidDistinct() {
        let duplicate = DigipeaterListParser.firstDuplicate(in: ["DRLNOD-2", "DRLNOD"], existing: [])
        XCTAssertNil(duplicate)
    }

    func testRecommendedPathDedupesPreservingOrder() {
        let deduped = DigipeaterListParser.dedupedPreservingOrder(["A", "B", "a", "C"])
        XCTAssertEqual(deduped, ["A", "B", "C"])
    }

    func testDuplicatePendingTokenDisablesAddAndShowsInlineError() {
        let vm = makeViewModel()
        vm.viaDigipeaters = ["DRLNOD"]
        vm.pendingViaTokenInput = "drlnod"

        XCTAssertFalse(vm.canAddPendingDigipeaters)
        XCTAssertEqual(vm.pendingViaDuplicateError, "DRLNOD is already in the path.")

        vm.ingestViaInput()
        XCTAssertEqual(vm.viaDigipeaters, ["DRLNOD"])
        XCTAssertEqual(vm.viaInputError, "DRLNOD is already in the path.")
    }

    func testApplyPathPresetSanitizesDuplicatesAndSetsNote() {
        let vm = makeViewModel()
        vm.applyPathPreset(["A", "B", "a", "C"])

        XCTAssertEqual(vm.viaDigipeaters, ["A", "B", "C"])
        XCTAssertEqual(vm.inlineNote, "Removed duplicate digis from path.")
    }

    func testKnownDigiAvailabilityUsesCurrentPathWithCallZeroEquivalence() {
        let vm = makeViewModel()
        vm.viaDigipeaters = ["DRLNOD"]

        XCTAssertTrue(vm.isDigipeaterUnavailableInCurrentPath("drlnod"))
        XCTAssertTrue(vm.isDigipeaterUnavailableInCurrentPath("DRLNOD-0"))
        XCTAssertFalse(vm.isDigipeaterUnavailableInCurrentPath("DRLNOD-2"))
    }

    func testRecommendedPathsAreSanitizedForDisplay() async {
        let vm = makeViewModel()
        vm.setMode(.ax25ViaDigi, for: .terminal)
        vm.applySuggestedTo("KB5YZB-7")

        vm.updateRuntimeData(
            stations: [],
            neighbors: [],
            routes: [
                RouteInfo(
                    destination: "KB5YZB-7",
                    origin: "DRL",
                    quality: 220,
                    path: ["DRL", "drl", "KB5YZB-7"],
                    lastUpdated: Date(),
                    sourceType: "classic"
                )
            ],
            packets: [],
            favorites: []
        )
        await waitForSuggestions()

        XCTAssertEqual(vm.recommendedDigiPaths.first?.digis, ["DRL"])
    }

    func testTacticalAliasValidAsAX25Destination() {
        let vm = makeViewModel()
        vm.setMode(.ax25, for: .terminal)

        for alias in ["DRL", "DRLBBS", "DRLNOD", "K0EPI"] {
            vm.applySuggestedTo(alias)
            vm.validate()
            XCTAssertTrue(vm.validationErrors.isEmpty, "\(alias) should be a valid AX.25 destination but got: \(vm.validationErrors)")
        }
    }

    func testSuggestedPathUnavailableWhenItSharesDigiWithCurrentPath() {
        let vm = makeViewModel()
        vm.viaDigipeaters = ["DRL"]

        XCTAssertTrue(vm.isSuggestedPathUnavailable(["DRLNOD", "DRL"]))
        XCTAssertTrue(vm.isSuggestedPathUnavailable(["drl-0"]))
        XCTAssertFalse(vm.isSuggestedPathUnavailable(["DRLNOD"]))
    }


    func testApplySidebarSelectionWithConnectActionPopulatesFields() {
        // Regression: with action .connect the reducer enters .connecting and the
        // published fields (toCall, mode, vias) were never applied — so the
        // subsequent buildIntent() saw an empty callsign and silently failed.
        let vm = ConnectBarViewModel()
        let selection = SidebarStationSelection(
            callsign: "KB5YZB-7",
            context: .stations,
            lastUsedMode: .ax25ViaDigi,
            hasNetRomRoute: false,
            viaDigipeaters: ["DRLNOD"]
        )

        vm.applySidebarSelection(selection, action: .connect)

        XCTAssertEqual(vm.toCall, "KB5YZB-7")
        XCTAssertEqual(vm.mode, .ax25ViaDigi)
        XCTAssertEqual(vm.viaDigipeaters, ["DRLNOD"])

        let intent = vm.buildIntent(sourceContext: .stations)
        XCTAssertEqual(intent.to, "KB5YZB-7")
        XCTAssertEqual(intent.validationErrors, [], "An immediate connect must not fail validation on an empty draft")
        if case .ax25ViaDigis(let digis) = intent.kind {
            XCTAssertEqual(digis.map(\.stringValue), ["DRLNOD"])
        } else {
            XCTFail("Expected via-digi intent, got \(intent.kind)")
        }
    }
}
