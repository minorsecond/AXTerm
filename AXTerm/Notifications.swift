//
//  Notifications.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/4/26.
//

import Foundation
import UserNotifications
import AppKit
import Combine

nonisolated enum NotificationAction {
    static let watchCategory = "WATCH_HIT"
    static let openPacket = "OPEN_PACKET"
    static let openApp = "OPEN_AXTERM"
    static let packetIDKey = "packetID"
}

protocol AppStateProviding {
    var isFrontmost: Bool { get }
}

nonisolated struct DefaultAppStateProvider: AppStateProviding {
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
    private static var testRetainedInstances: [UserNotificationScheduler] = []
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

        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            Self.testRetainedInstances.append(self)
        }
    }

    func scheduleWatchNotification(packet: Packet, match: WatchMatch) {
        guard settings.notifyOnWatchHits else { return }
        if settings.notifyOnlyWhenInactive && appState.isFrontmost {
            return
        }

        SentryManager.shared.addBreadcrumb(
            category: "notifications",
            message: "Schedule watch notification",
            level: .info,
            data: ["packetID": packet.id.uuidString]
        )

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
            await MainActor.run {
                SentryManager.shared.captureNotificationFailure("requestAuthorization", error: error)
            }
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
    private static var testRetainedInstances: [PacketInspectionRouter] = []
    @Published private(set) var requestedPacketID: Packet.ID?
    @Published private(set) var shouldOpenMainWindow = false

    init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            Self.testRetainedInstances.append(self)
        }
    }

    func requestOpenMainWindow() {
        SentryManager.shared.addBreadcrumb(category: "ui.routing", message: "Request open main window", level: .info, data: nil)
        shouldOpenMainWindow = true
    }

    func requestOpenPacket(id: Packet.ID) {
        SentryManager.shared.breadcrumbInspectorRouteRequest(packetID: id)
        requestedPacketID = id
        shouldOpenMainWindow = true
    }

    func consumeOpenWindowRequest() {
        SentryManager.shared.addBreadcrumb(category: "ui.routing", message: "Consume open main window request", level: .info, data: nil)
        shouldOpenMainWindow = false
    }

    func consumePacketRequest() {
        SentryManager.shared.breadcrumbInspectorRouteRequest(packetID: requestedPacketID)
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
