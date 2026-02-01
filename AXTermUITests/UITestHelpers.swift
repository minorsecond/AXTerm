//
//  UITestHelpers.swift
//  AXTermUITests
//
//  Created by Ross Wardrup on 1/30/26.
//

import AppKit
import Darwin
import Foundation

enum UITestHelpers {
    static func isAppRunning(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier || $0.localizedName == "AXTerm"
        }
    }

    static func terminateRunningApp(bundleIdentifier: String, timeout: TimeInterval = 5) {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleIdentifier || $0.localizedName == "AXTerm"
        }
        guard !runningApps.isEmpty else { return }

        for app in runningApps {
            app.terminate()
            let deadline = Date().addingTimeInterval(timeout)
            while !app.isTerminated && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            app.forceTerminate()
            let hardDeadline = Date().addingTimeInterval(timeout)
            while !app.isTerminated && Date() < hardDeadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            _ = kill(app.processIdentifier, SIGKILL)
        }
    }
}
