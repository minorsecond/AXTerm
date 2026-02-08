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
}
