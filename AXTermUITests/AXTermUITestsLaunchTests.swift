//
//  AXTermUITestsLaunchTests.swift
//  AXTermUITests
//
//  Created by Ross Wardrup on 1/28/26.
//

import XCTest

final class AXTermUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        UITestHelpers.terminateRunningApp(bundleIdentifier: "com.rosswardrup.AXTerm")
    }

    @MainActor
    func testLaunch() throws {
        UITestHelpers.terminateRunningApp(bundleIdentifier: "com.rosswardrup.AXTerm")
        guard !UITestHelpers.isAppRunning(bundleIdentifier: "com.rosswardrup.AXTerm") else {
            return
        }
        let app = XCUIApplication()
        app.launch()
        defer {
            if app.state != .notRunning {
                app.terminate()
            }
        }

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
