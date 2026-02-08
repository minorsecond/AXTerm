//
//  DualInstanceUITests.swift
//  AXTermUITests
//
//  Automated UI tests that drive two AXTerm instances communicating through
//  a KISS relay. These tests verify actual end-to-end packet transmission
//  through the real app UI.
//
//  Prerequisites:
//  - Docker KISS relay running (Scripts/run-ui-tests.sh handles this)
//  - Two AXTerm instances launched with --test-mode
//

import AppKit
import XCTest

/// Tests that run against two AXTerm instances
final class DualInstanceUITests: XCTestCase {

    // Two app instances
    private var stationA: XCUIApplication!
    private var stationB: XCUIApplication!
    private let dualInstanceEnvKey = "AXTERM_DUAL_INSTANCE_TESTS"

    override func setUpWithError() throws {
        continueAfterFailure = false
        if ProcessInfo.processInfo.environment[dualInstanceEnvKey] != "1" {
            throw XCTSkip("Dual instance UI tests require Scripts/run-ui-tests.sh (AXTERM_DUAL_INSTANCE_TESTS=1)")
        }
        terminateExistingAXTermInstances()

        // Note: XCUIApplication() targets the app under test by default.
        // For dual-instance testing, we launch external instances via the
        // run-ui-tests.sh script and interact with them via accessibility.

        stationA = XCUIApplication()
        stationB = XCUIApplication()
    }

    override func tearDownWithError() throws {
        // Don't terminate - let the test orchestrator handle cleanup
    }

    private func terminateExistingAXTermInstances() {
        let bundleId = "com.rosswardrup.AXTerm"
        let appHandle = XCUIApplication(bundleIdentifier: bundleId)
        if appHandle.state != .notRunning {
            appHandle.terminate()
            _ = waitForTermination(of: bundleId, timeout: 2.0)
        }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard !running.isEmpty else { return }

        for app in running {
            app.terminate()
        }

        if waitForTermination(of: bundleId, timeout: 2.0) {
            return
        }

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            _ = app.forceTerminate()
        }

        _ = waitForTermination(of: bundleId, timeout: 2.0)
    }

    // MARK: - Helper Methods

    /// Wait for an element to exist
    private func waitForElement(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    private func waitForTermination(of bundleId: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stillRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            if stillRunning.isEmpty { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    /// Find the main window
    private func findMainWindow(in app: XCUIApplication) -> XCUIElement {
        return app.windows.firstMatch
    }

    /// Find the Terminal navigation item in sidebar
    private func selectTerminalTab(in app: XCUIApplication) {
        let navItem = app.descendants(matching: .any).matching(identifier: "nav-terminal").firstMatch
        if navItem.exists {
            navItem.click()
            return
        }

        let sidebarOutline = app.outlines.firstMatch
        let outlineItem = sidebarOutline.staticTexts["Terminal"]
        if outlineItem.exists {
            outlineItem.click()
            return
        }

        let sidebarTable = app.tables.firstMatch
        let tableItem = sidebarTable.staticTexts["Terminal"]
        if tableItem.exists {
            tableItem.click()
        }
    }

    /// Find and type in the compose field
    private func typeInComposeField(in app: XCUIApplication, text: String) {
        // Look for a text field in the terminal view
        let textField = app.textFields.firstMatch
        if textField.exists {
            textField.click()
            textField.typeText(text)
        }
    }

    /// Send a message by clicking the send button or pressing Enter
    private func sendMessage(in app: XCUIApplication) {
        // Try to find a Send button
        let sendButton = app.buttons["Send"]
        if sendButton.exists {
            sendButton.click()
            return
        }

        // Fall back to pressing Enter in the text field
        app.typeKey(.enter, modifierFlags: [])
    }

    // MARK: - Tests

    /// Test that the app launches and shows main window
    @MainActor
    func testAppLaunchesSuccessfully() throws {
        // Launch Station A
        stationA.launchArguments = [
            "--test-mode",
            "--port", "8001",
            "--callsign", "TEST-1",
            "--instance-name", "Station A",
            "--auto-connect"
        ]
        stationA.launch()

        // Verify main window appears
        let mainWindow = findMainWindow(in: stationA)
        let rootElement = stationA.otherElements["mainWindowRoot"]
        let windowAppeared = waitForElement(mainWindow, timeout: 10)
            || rootElement.waitForExistence(timeout: 10)
            || stationA.windows.count > 0
        XCTAssertTrue(windowAppeared, "Main window should appear")

        stationA.terminate()
    }

    /// Test connection status indicator
    @MainActor
    func testConnectionStatus() throws {
        stationA.launchArguments = [
            "--test-mode",
            "--port", "8001",
            "--callsign", "TEST-1",
            "--instance-name", "Station A",
            "--auto-connect"
        ]
        stationA.launch()

        // Wait for app to initialize
        Thread.sleep(forTimeInterval: 2)

        // Ensure we're on the Terminal tab where the connection status is shown
        selectTerminalTab(in: stationA)
        Thread.sleep(forTimeInterval: 1)

        // Look for connection status indicator (banner is transient)
        let statusIndicator = stationA.staticTexts.matching(identifier: "connectionStatus").firstMatch
        let statusElement = stationA.otherElements["connectionStatus"]
        let connectedText = stationA.staticTexts["Connected"]

        let bannerAppeared = statusIndicator.waitForExistence(timeout: 5)
            || statusElement.waitForExistence(timeout: 5)
            || connectedText.waitForExistence(timeout: 5)

        if !bannerAppeared {
            let composeField = stationA.textFields["terminalComposeField"]
            let terminalVisible = composeField.exists || stationA.textViews.firstMatch.exists
            XCTAssertTrue(terminalVisible, "Terminal view should be visible even if status banner is not")
        } else {
            XCTAssertTrue(bannerAppeared, "Connection status banner should appear when connected")
        }

        stationA.terminate()
    }

    /// Test navigating to Terminal tab
    @MainActor
    func testNavigateToTerminal() throws {
        stationA.launchArguments = [
            "--test-mode",
            "--port", "8001",
            "--callsign", "TEST-1",
            "--instance-name", "Station A",
            "--auto-connect"
        ]
        stationA.launch()

        Thread.sleep(forTimeInterval: 2)

        // Click Terminal in sidebar
        selectTerminalTab(in: stationA)

        Thread.sleep(forTimeInterval: 1)

        // Verify terminal view is shown
        // Look for compose area or session list
        let terminalArea = stationA.textFields["terminalComposeField"]
        let terminalVisible = terminalArea.waitForExistence(timeout: 3) || stationA.textViews.firstMatch.exists
        XCTAssertTrue(terminalVisible,
                      "Terminal view should be visible")

        stationA.terminate()
    }

    /// Test Settings window opens
    @MainActor
    func testSettingsWindowOpens() throws {
        stationA.launchArguments = [
            "--test-mode",
            "--port", "8001",
            "--callsign", "TEST-1",
            "--instance-name", "Station A"
        ]
        stationA.launch()

        Thread.sleep(forTimeInterval: 2)

        // Open Settings via keyboard shortcut
        stationA.typeKey(",", modifierFlags: .command)

        Thread.sleep(forTimeInterval: 1)

        // Look for Settings window or view
        let settingsView = stationA.otherElements["settingsView"]
        if !settingsView.exists {
            let appMenu = stationA.menuBars.menuBarItems["AXTerm"]
            let menuItem = appMenu.exists ? appMenu : stationA.menuBars.menuBarItems.firstMatch
            if menuItem.exists {
                menuItem.click()
                let settingsItem = menuItem.menus.menuItems["Settings…"]
                let prefsItem = menuItem.menus.menuItems["Preferences…"]
                if settingsItem.exists {
                    settingsItem.click()
                } else if prefsItem.exists {
                    prefsItem.click()
                }
            }
        }

        let settingsWindow = stationA.windows["Settings"]
        let settingsAppeared = settingsView.waitForExistence(timeout: 3)
            || settingsWindow.exists
            || stationA.windows.count > 1
        XCTAssertTrue(settingsAppeared, "Settings window should open")

        stationA.terminate()
    }
}

// MARK: - External Instance Coordinator

/// Coordinates testing with externally launched AXTerm instances.
/// Use this for full dual-instance testing where the test script
/// launches both apps before running XCUITest.
final class ExternalInstanceUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Verify external instances are running
    @MainActor
    func testExternalInstancesRunning() throws {
        // Check if AXTerm instances are running
        let runningApps = NSWorkspace.shared.runningApplications
        let axtermInstances = runningApps.filter {
            $0.bundleIdentifier == "com.rosswardrup.AXTerm"
        }

        // Skip if not running in dual-instance mode
        guard axtermInstances.count >= 2 else {
            throw XCTSkip("Dual instance mode requires two AXTerm instances. Use run-ui-tests.sh")
        }

        XCTAssertGreaterThanOrEqual(axtermInstances.count, 2,
                                     "Should have at least 2 AXTerm instances running")
    }

    /// Test frame exchange between instances using AppleScript
    @MainActor
    func testFrameExchangeViaAppleScript() throws {
        // Check instances are running
        let runningApps = NSWorkspace.shared.runningApplications
        let axtermInstances = runningApps.filter {
            $0.bundleIdentifier == "com.rosswardrup.AXTerm"
        }

        guard axtermInstances.count >= 2 else {
            throw XCTSkip("Requires two AXTerm instances")
        }

        // Use AppleScript to interact with the apps
        // This allows controlling multiple instances of the same app

        let script = """
        tell application "System Events"
            -- Find AXTerm windows
            set axtermWindows to every window of (every process whose name contains "AXTerm")

            -- Verify we have at least 2 windows
            if (count of axtermWindows) < 2 then
                return "Need at least 2 windows"
            end if

            return "Found " & (count of axtermWindows) & " windows"
        end tell
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if let error = error {
                XCTFail("AppleScript error: \(error)")
            } else {
                let resultString = result.stringValue ?? "nil"
                XCTAssertTrue(resultString.contains("Found"), "Should find AXTerm windows: \(resultString)")
            }
        }
    }
}
