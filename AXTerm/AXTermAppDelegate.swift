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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
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
