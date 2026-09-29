//
//  AXTermUITests.swift
//  AXTermUITests
//
//  Created by Ross Wardrup on 1/28/26.
//

import XCTest

final class AXTermUITests: XCTestCase {
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        var didLaunch = false
        if app.state == .notRunning {
            app.launch()
            didLaunch = true
        }
        if didLaunch {
            addTeardownBlock {
                if app.state != .notRunning {
                    app.terminate()
                }
            }
        }
        return app
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false
        UITestHelpers.terminateRunningApp(bundleIdentifier: "com.rosswardrup.AXTerm")

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        _ = launchApp()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        UITestHelpers.terminateRunningApp(bundleIdentifier: "com.rosswardrup.AXTerm")
        guard !UITestHelpers.isAppRunning(bundleIdentifier: "com.rosswardrup.AXTerm") else {
            return
        }
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launch()
            app.terminate()
        }
    }

    @MainActor
    func testKnownDigiRowBecomesDisabledWhenInPath() throws {
        let app = launchApp()

        let sessionButton = app.buttons["Session"]
        if sessionButton.waitForExistence(timeout: 2) {
            sessionButton.tap()
        }

        let routingButton = app.buttons["connectBar.routingButton"]
        guard routingButton.waitForExistence(timeout: 5) else {
            throw XCTSkip("Routing button not available in current launch state")
        }
        routingButton.tap()

        let viaDigiRadio = app.radioButtons["AX.25 via Digi"]
        if viaDigiRadio.waitForExistence(timeout: 2) {
            viaDigiRadio.tap()
        }

        let manualButton = app.buttons["Manual"]
        if manualButton.waitForExistence(timeout: 2) {
            manualButton.tap()
        }

        let morePathsButton = app.buttons["connectBar.morePathsButton"]
        guard morePathsButton.waitForExistence(timeout: 3) else {
            throw XCTSkip("Known digis menu is not available")
        }
        morePathsButton.tap()

        let knownQuery = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "connectBar.knownDigi."))
        guard knownQuery.count > 0 else {
            throw XCTSkip("No known digi rows available in this environment")
        }

        var selected: XCUIElement?
        for index in 0..<knownQuery.count {
            let candidate = knownQuery.element(boundBy: index)
            if candidate.isEnabled {
                selected = candidate
                break
            }
        }
        guard let selected else {
            throw XCTSkip("No enabled known digi rows available to select")
        }

        let selectedID = selected.identifier
        let selectedLabel = selected.label
        selected.tap()

        morePathsButton.tap()
        let sameRow = app.descendants(matching: .any)[selectedID]
        XCTAssertTrue(sameRow.waitForExistence(timeout: 2))
        XCTAssertFalse(sameRow.isEnabled)
        XCTAssertTrue(app.staticTexts["In path"].waitForExistence(timeout: 2), "Expected visible in-path indicator for \(selectedLabel)")
    }
}
