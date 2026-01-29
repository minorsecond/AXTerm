//
//  Notifications.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import Foundation
import UserNotifications
import AppKit

enum NotificationAction {
    static let watchCategory = "WATCH_HIT"
    static let openPacket = "OPEN_PACKET"
    static let openApp = "OPEN_AXTERM"
    static let packetIDKey = "packetID"
}

protocol AppStateProviding {
    var isFrontmost: Bool { get }
}

struct DefaultAppStateProvider: AppStateProviding {
    var isFrontmost: Bool {
        NSApp.isActive
    }
}

protocol NotificationCenterScheduling {
    func add(_ request: UNNotificationRequest)
}

extension UNUserNotificationCenter: NotificationCenterScheduling {
    func add(_ request: UNNotificationRequest) {
        add(request, withCompletionHandler: { _ in })
    }
}

final class UserNotificationScheduler: NotificationScheduling {
    private let center: NotificationCenterScheduling
    private let settings: AppSettingsStore
    private let appState: AppStateProviding

    init(
        center: NotificationCenterScheduling = UNUserNotificationCenter.current(),
        settings: AppSettingsStore,
        appState: AppStateProviding
    ) {
        self.center = center
        self.settings = settings
        self.appState = appState
    }

    func scheduleWatchNotification(packet: Packet, match: WatchMatch) {
        guard settings.notifyOnWatchHits else { return }
        if settings.notifyOnlyWhenInactive && appState.isFrontmost {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Watch hit: \(packet.fromDisplay) → \(packet.toDisplay)"
        content.body = packet.infoPreview.isEmpty ? "Packet received" : packet.infoPreview
        content.categoryIdentifier = NotificationAction.watchCategory
        content.userInfo = [NotificationAction.packetIDKey: packet.id.uuidString]
        if settings.notifyPlaySound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: packet.id.uuidString,
            content: content,
            trigger: nil
        )

        center.add(request)
    }
}

final class NotificationAuthorizationManager {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        configureCategories()
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }

    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "AXTerm Test"
        content.body = "Notifications are enabled."
        content.categoryIdentifier = NotificationAction.watchCategory
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { _ in }
    }

    private func configureCategories() {
        let openPacket = UNNotificationAction(
            identifier: NotificationAction.openPacket,
            title: "Open Packet",
            options: [.foreground]
        )
        let openApp = UNNotificationAction(
            identifier: NotificationAction.openApp,
            title: "Open AXTerm",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: NotificationAction.watchCategory,
            actions: [openPacket, openApp],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }
}

@MainActor
final class PacketInspectionRouter: ObservableObject {
    @Published private(set) var requestedPacketID: Packet.ID?
    @Published private(set) var shouldOpenMainWindow = false

    func requestOpenMainWindow() {
        shouldOpenMainWindow = true
    }

    func requestOpenPacket(id: Packet.ID) {
        requestedPacketID = id
        shouldOpenMainWindow = true
    }

    func consumeOpenWindowRequest() {
        shouldOpenMainWindow = false
    }

    func consumePacketRequest() {
        requestedPacketID = nil
    }
}

final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {
    private let router: PacketInspectionRouter

    init(router: PacketInspectionRouter) {
        self.router = router
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [router] in
            let userInfo = response.notification.request.content.userInfo
            let packetIDString = userInfo[NotificationAction.packetIDKey] as? String
            let packetID = packetIDString.flatMap(UUID.init)

            switch response.actionIdentifier {
            case NotificationAction.openPacket:
                if let packetID {
                    router.requestOpenPacket(id: packetID)
                } else {
                    router.requestOpenMainWindow()
                }
            default:
                router.requestOpenMainWindow()
            }
            completionHandler()
        }
    }
}
