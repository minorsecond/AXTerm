import XCTest
@testable import AXTerm

@MainActor
final class DestinationPickerViewModelTests: XCTestCase {
    func testCallsignNormalizationAndValidation() {
        XCTAssertEqual(DestinationPickerViewModel.sanitizeForTyping(" kb5yzb-7  "), "KB5YZB-7")
        XCTAssertEqual(DestinationPickerViewModel.normalizeCandidate("k b5 yz b-7"), "KB5YZB-7")

        XCTAssertEqual(DestinationPickerViewModel.validateCandidate("KB5YZB").isValid, true)
        XCTAssertEqual(DestinationPickerViewModel.validateCandidate("KB5YZB-15").isValid, true)

        let invalid = DestinationPickerViewModel.validateCandidate("KB5YZB-16")
        if case .invalid = invalid {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected invalid state for SSID 16")
        }
    }

    func testFuzzyRankingPrefersPrefixThenContains() {
        let ranked = DestinationPickerViewModel.rankedSuggestions(
            query: "DRL",
            candidates: ["ZZDRL", "DRLNODE", "K0EPI", "ADRLB"]
        )

        XCTAssertEqual(ranked.first, "DRLNODE")
        XCTAssertTrue(ranked.contains("ZZDRL"))
        XCTAssertTrue(ranked.contains("ADRLB"))
    }

    func testAliasLinkingRequiresEvidence() {
        let suiteName = "DestinationPickerViewModelTests.alias"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create UserDefaults suite \(suiteName)")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let vm = DestinationPickerViewModel(defaults: defaults)

        XCTAssertFalse(vm.hasAliasLink(between: "DRL", and: "DRLNODE"))
        XCTAssertNil(vm.linkedAlias(for: "DRL"))

        vm.registerAliasEvidence(between: "DRL", and: "DRLNODE", source: .digipeatReference)

        XCTAssertTrue(vm.hasAliasLink(between: "DRL", and: "DRLNODE"))
        XCTAssertEqual(vm.linkedAlias(for: "DRL"), "DRLNODE")

        vm.removeAliasLink(between: "DRL", and: "DRLNODE")
        XCTAssertFalse(vm.hasAliasLink(between: "DRL", and: "DRLNODE"))
    }

    /// Browsing (no query) shows only local — the far reachable-via-node hops
    /// stay hidden so hundreds of relayed nodes don't bury the local list, and
    /// the local sections themselves are capped so a busy channel opens fast.
    func testBrowsingHidesReachableAndCapsLocal() {
        let vm = DestinationPickerViewModel()

        var reachableVia: [String: String] = [:]
        var reachable: [String] = []
        for i in 0..<80 {
            let dest = "COSCODEST\(i)"
            reachableVia[dest] = "COSCO"
            reachable.append(dest)
        }
        // 40 recently-heard local stations (a busy channel).
        let recents = (0..<40).map { "LOCAL\($0)" }

        vm.updateDataSources(
            groups: [
                ConnectSuggestionGroup(id: "recent", title: "Recent Heard", values: recents),
                ConnectSuggestionGroup(id: "reachable", title: "Reachable via nodes", values: reachable)
            ],
            reachableVia: reachableVia)

        let reachableSections = vm.visibleSections.filter { $0.id.hasPrefix("reachable::") }
        XCTAssertTrue(reachableSections.isEmpty, "relayed hops are hidden until the operator types")
        let recentRows = vm.visibleSections.first { $0.id == "recent" }?.rows.count ?? 0
        XCTAssertLessThanOrEqual(recentRows, 12, "the local list is capped while browsing")
    }

    /// Filtering opens the set back up — the query has already made it choosable.
    func testReachableDestinationsExpandWhenFiltering() {
        let vm = DestinationPickerViewModel()
        var reachableVia: [String: String] = [:]
        var all: [String] = []
        for i in 0..<20 {
            let dest = "COSCODEST\(i)"   // all reachable via COSCO, share a prefix
            reachableVia[dest] = "COSCO"
            all.append(dest)
        }
        vm.updateDataSources(
            groups: [ConnectSuggestionGroup(id: "reachable", title: "Reachable via nodes", values: all)],
            reachableVia: reachableVia)

        vm.handleTypedTextChanged("COSCODEST", autoOpenPopover: false)
        let rows = vm.visibleSections.filter { $0.id.hasPrefix("reachable::") }.flatMap(\.rows)
        XCTAssertGreaterThan(rows.count, 6, "filtering shows more than the browsing cap of 6")
    }
}
