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
}
