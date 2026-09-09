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
        let coordinator = SessionCoordinator.shared
        let discCount = coordinator?.prepareForTermination() ?? 0
        let radioManager = coordinator?.packetEngine?.radioManager
        let anyConnected = radioManager?.radioStates.values.contains(.connected) ?? false
        guard discCount > 0 || anyConnected else { return .terminateNow }
        // Brief grace so DISC bytes flush through the KISS link before the
        // process dies, THEN release the radio links so the IC-705's LAN slot,
        // PTT and audio are freed at quit instead of being held until the radio
        // times them out — a held slot was why the next launch's reconnect had
        // to be retried. A final short moment lets the Icom token-release
        // datagrams leave before the sockets die with the process.
        // reply(toApplicationShouldTerminate:) must land exactly once, and it
        // must land even if a link's close stalls — otherwise the app sits in
        // .terminateLater until macOS force-kills it (SIGTERM). A one-shot
        // guard plus an absolute fallback deadline guarantee the quit always
        // completes; whichever timer fires first wins, the other is a no-op.
        var replied = false
        let replyOnce: () -> Void = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            radioManager?.closeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: replyOnce)
        }
        // Backstop: reply no later than this regardless of how the close goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: replyOnce)
        return .terminateLater
    }
}
