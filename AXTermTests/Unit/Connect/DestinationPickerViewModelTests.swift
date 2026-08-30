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

    /// A big relay neighbourhood must not flatten into one endless scroll: the
    /// reachable destinations are grouped per via-node and capped while browsing.
    func testReachableDestinationsAreGroupedAndCappedWhenBrowsing() {
        let vm = DestinationPickerViewModel()

        // 8 relays, 10 destinations each = 80 reachable destinations.
        var reachableVia: [String: String] = [:]
        var all: [String] = []
        let nodes = ["COSCO", "SOLBPQ", "KB5YZB-7", "DRLNOD", "RELAY5", "RELAY6", "RELAY7", "RELAY8"]
        for (n, node) in nodes.enumerated() {
            for i in 0..<10 {
                let dest = "N\(n)DEST\(i)"
                reachableVia[dest] = node
                all.append(dest)
            }
        }

        vm.updateDataSources(
            groups: [ConnectSuggestionGroup(id: "reachable", title: "Reachable via nodes", values: all)],
            reachableVia: reachableVia)

        let reachableSections = vm.visibleSections.filter { $0.id.hasPrefix("reachable::") }
        XCTAssertLessThanOrEqual(reachableSections.count, 6, "browsing shows a taster of relays, not all 8")
        XCTAssertTrue(reachableSections.allSatisfy { $0.rows.count <= 6 }, "each relay is capped while browsing")
        let totalRows = reachableSections.reduce(0) { $0 + $1.rows.count }
        XCTAssertLessThanOrEqual(totalRows, 60, "total reachable rows are bounded")
        XCTAssertTrue(reachableSections.allSatisfy { $0.title.hasPrefix("Via ") }, "grouped under the reaching node")
        // A capped relay's header carries its true count so the operator narrows.
        XCTAssertTrue(reachableSections.contains { $0.title.contains("(10)") })
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
