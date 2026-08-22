//
//  TemporaryShowAllOverrideTests.swift
//  AXTermTests
//
//  The "Show All (Temporary)" preview must be a non-persistent override.
//  It previously wrote `settings.ignoredServiceEndpoints = []`, so a crash or
//  quit while the preview was active permanently destroyed the user's ignore
//  list. These tests pin the contract: entering the preview never mutates
//  persisted settings, and the list survives an app-restart simulation with no
//  exit path having run.
//

import XCTest
@testable import AXTerm

@MainActor
final class TemporaryShowAllOverrideTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        Telemetry.setBackend(NoOpTelemetryBackend())
        suiteName = "AXTermTests-TemporaryShowAll-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    override func tearDown() {
        // CallsignValidator holds process-global state; leave it clean for other suites.
        CallsignValidator.configureIgnoredServiceEndpoints([])
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    private func makeViewModel(settings: AppSettingsStore) -> AnalyticsDashboardViewModel {
        AnalyticsDashboardViewModel(
            settingsStore: settings,
            calendar: Calendar(identifier: .gregorian),
            packetDebounce: 0,
            graphDebounce: 0,
            packetScheduler: .main
        )
    }

    func testTemporaryShowAllDoesNotMutatePersistedIgnoreList() async {
        let settings = AppSettingsStore(defaults: defaults)
        settings.addIgnoredServiceEndpoint("K9SVC")
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("K9SVC"),
                       "Precondition: the ignored endpoint is filtered")

        let viewModel = makeViewModel(settings: settings)
        viewModel.setTemporarilyShowingIgnoredEndpoints(true)

        // The preview takes effect (the endpoint is no longer filtered)…
        XCTAssertTrue(CallsignValidator.isValidRoutingNode("K9SVC"),
                      "Preview must show ignored endpoints")
        // …but the persisted list is untouched.
        XCTAssertTrue(settings.ignoredServiceEndpoints.contains("K9SVC"),
                      "Preview must never mutate the persisted ignore list")
        await Task.yield()
        _ = viewModel
    }

    func testIgnoreListSurvivesRestartWhilePreviewActive() async {
        let settings = AppSettingsStore(defaults: defaults)
        settings.addIgnoredServiceEndpoint("K9SVC")

        let viewModel = makeViewModel(settings: settings)
        viewModel.setTemporarilyShowingIgnoredEndpoints(true)
        // Deliberately no exit: the app "crashes" here.

        // App restart: a fresh settings store over the same persisted defaults.
        let restarted = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(restarted.ignoredServiceEndpoints.contains("K9SVC"),
                      "Ignore list must survive a crash during temporary show-all")
        // The restarted app filters again — the override was session state only.
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("K9SVC"),
                       "After restart the ignore list is enforced again")
        await Task.yield()
        _ = viewModel
    }

    func testDisablingOverrideRestoresFiltering() async {
        let settings = AppSettingsStore(defaults: defaults)
        settings.addIgnoredServiceEndpoint("K9SVC")

        let viewModel = makeViewModel(settings: settings)
        viewModel.setTemporarilyShowingIgnoredEndpoints(true)
        XCTAssertTrue(CallsignValidator.isValidRoutingNode("K9SVC"))

        viewModel.setTemporarilyShowingIgnoredEndpoints(false)
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("K9SVC"),
                       "Exiting the preview restores filtering from the untouched settings")
        XCTAssertTrue(settings.ignoredServiceEndpoints.contains("K9SVC"))
        await Task.yield()
        _ = viewModel
    }

    func testSettingsChangeDuringPreviewKeepsOverrideEffective() async {
        let settings = AppSettingsStore(defaults: defaults)
        settings.addIgnoredServiceEndpoint("K9SVC")

        let viewModel = makeViewModel(settings: settings)
        viewModel.setTemporarilyShowingIgnoredEndpoints(true)
        XCTAssertTrue(CallsignValidator.isValidRoutingNode("K9SVC"))

        // A settings edit mid-preview reconfigures the validator in its didSet;
        // the view model must re-apply the override.
        settings.addIgnoredServiceEndpoint("K8SVC")
        // The settings publisher delivers on the main run loop.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(CallsignValidator.isValidRoutingNode("K9SVC"),
                      "Override must survive a settings edit during the preview")
        XCTAssertTrue(CallsignValidator.isValidRoutingNode("K8SVC"))
        XCTAssertEqual(Set(settings.ignoredServiceEndpoints), ["K9SVC", "K8SVC"])

        viewModel.setTemporarilyShowingIgnoredEndpoints(false)
        XCTAssertFalse(CallsignValidator.isValidRoutingNode("K8SVC"))
    }
}
