//
//  MainWindowAtLaunchTests.swift
//  AXTermTests
//
//  The main window opens at launch even when the app is started with
//  command-line arguments.
//
//  Smoke run 2026-10-03-1, issue 79: test instances launched with
//  `--instance-name "Station A" --callsign K0EPI` came up with no window.
//  AppKit treats a command-line argument that does not start with "-" as a
//  file to open, so "Station A" and "K0EPI" made the launch an open-documents
//  launch: no `oapp` event, no open-untitled step, and nothing it could open.
//  Shown on 2026-10-06 with a fresh copy of the app: `--test-mode` alone
//  opened the window, adding `--instance-name "Station E"` did not, and the
//  same value written "-Station E" did. An unclean exit hid it, because
//  restoration brought the window back.
//
//  AXTerm opens no documents, so it tells AppKit not to read arguments as
//  files (NSTreatUnknownArgumentsAsOpen = NO).
//
//  The value must be the string "NO". AppKit's finishLaunching reads it
//  with objectForKey: and sends it compare:options: against @"NO", so the
//  Boolean false registered at first crashed every launch of the main app
//  ("-[__NSCFBoolean compare:options:]: unrecognized selector"), found
//  starting it for tests 10.4 and 11.2 on 2026-10-06.
//

import XCTest
@testable import AXTerm

final class MainWindowAtLaunchTests: XCTestCase {

    func testArgumentsAreNotTreatedAsFilesToOpen() throws {
        let suite = "MainWindowAtLaunchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        AXTermAppDelegate.registerLaunchDefaults(in: defaults)

        // Read the registration domain itself: Xcode starts the test host with
        // "-NSTreatUnknownArgumentsAsOpen NO" on the command line, which
        // outranks a registered default and hid the Boolean.
        let registered = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        let value = registered["NSTreatUnknownArgumentsAsOpen"]
        XCTAssertNotNil(value)
        XCTAssertTrue(value is String, "AppKit sends it compare:options:, so it must be a string, not \(type(of: value))")
        XCTAssertEqual(value as? String, "NO")
    }
}
