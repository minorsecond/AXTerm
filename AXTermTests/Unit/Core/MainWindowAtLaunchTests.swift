//
//  MainWindowAtLaunchTests.swift
//  AXTermTests
//
//  The main window opens at launch however the app was started.
//
//  Smoke run 2026-10-03-1, issue 79: test instances launched with `open` or
//  from a shell opened no window at all, every time on 2026-10-05 and
//  2026-10-06, and File > New was the only way in. AppKit skipped its
//  open-untitled step at launch, which is where SwiftUI makes a
//  WindowGroup's first window (confirmed by asking the running app: no
//  windows, the delegate would have opened one, and calling
//  applicationOpenUntitledFile made it at once). Window restoration had
//  nothing to restore and played no part.
//

import XCTest
@testable import AXTerm

final class MainWindowAtLaunchTests: XCTestCase {

    func testWithNoMainWindowOneIsOpened() {
        XCTAssertTrue(AXTermAppDelegate.needsMainWindow(isHidden: false, windowIdentifiers: []))
    }

    func testOtherWindowsDoNotCountAsTheMainWindow() {
        // The menu-bar item's window has no identifier; Diagnostics is a window of its own.
        XCTAssertTrue(AXTermAppDelegate.needsMainWindow(
            isHidden: false, windowIdentifiers: ["", "diagnostics-AppWindow-1", "winlinkMap-AppWindow-1"]))
    }

    func testAMainWindowAlreadyOpenIsLeftAlone() {
        XCTAssertFalse(AXTermAppDelegate.needsMainWindow(
            isHidden: false, windowIdentifiers: ["main-AppWindow-1"]))
        XCTAssertFalse(AXTermAppDelegate.needsMainWindow(
            isHidden: false, windowIdentifiers: ["main-AppWindow-2", ""]))
    }

    /// Launched hidden (a login item set to hide), the operator asked for no window.
    func testAHiddenLaunchStaysHidden() {
        XCTAssertFalse(AXTermAppDelegate.needsMainWindow(isHidden: true, windowIdentifiers: []))
    }
}
