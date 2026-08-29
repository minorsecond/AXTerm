//
//  AXTermAppDelegate.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import AppKit
import UserNotifications

final class AXTermAppDelegate: NSObject, NSApplicationDelegate {
    var settings: AppSettingsStore?
    let notificationHandler = NotificationActionHandler(router: .shared)

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notificationHandler
        // The unit-test host must not flash a window or steal focus:
        // stay a background process and put away anything SwiftUI
        // already ordered in. UI tests keep the real app.
        // .accessory, not .prohibited: the harder policy interferes
        // with XCTest's runner bootstrap on some clones.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            NSApp.setActivationPolicy(.accessory)
            for window in NSApp.windows { window.orderOut(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The test host hides its window; that must never read as "quit".
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return false
        }
        guard let settings else { return false }
        return !settings.runInMenuBar
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Graceful link teardown: DISC every live session so peers drop their
        // side immediately instead of polling a zombie until their retry limit
        // exhausts. Without this, quitting mid-session simply vanished — the
        // peer kept the link "up" for minutes (observed with KB5YZB-7's node
        // retransmitting stale session data at our fresh SABMs).
        guard let coordinator = SessionCoordinator.shared,
              coordinator.prepareForTermination() > 0 else {
            return .terminateNow
        }
        // Brief grace so the DISC bytes flush through the KISS link (TCP/BLE/
        // serial) before the process — and its socket — die. Once the TNC has
        // the frame it transmits regardless of our exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
