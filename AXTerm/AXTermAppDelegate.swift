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
    var notificationDelegate: UNUserNotificationCenterDelegate? {
        didSet {
            UNUserNotificationCenter.current().delegate = notificationDelegate
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let settings else { return false }
        return !settings.runInMenuBar
    }
}
