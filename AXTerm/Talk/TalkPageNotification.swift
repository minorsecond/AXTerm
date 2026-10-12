//
//  TalkPageNotification.swift
//  AXTerm
//
//  The system notification for a TALK page, with Answer and Not Now.
//

import Foundation
import UserNotifications

nonisolated enum TalkPageNotification {
    static let category = "TALK_REQUEST"
    static let pageKey = "talkPage"

    static let answerAction = "TALK_ANSWER"
    static let declineAction = "TALK_DECLINE"

    /// What the notification says, and which page its buttons act on.
    static func content(caller: String, door: TalkRouter.Door, pageID: UUID) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(caller) wants to talk"
        let place = TalkBannerText.place(door)
        content.body = place.prefix(1).uppercased() + place.dropFirst()
            + ". Nobody answering in a minute tells them you're away."
        content.categoryIdentifier = category
        content.userInfo = [pageKey: pageID.uuidString]
        content.sound = .default
        return content
    }

    /// The category's buttons, registered with the app's others.
    static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: category,
            actions: [
                UNNotificationAction(identifier: answerAction, title: "Answer", options: [.foreground]),
                UNNotificationAction(identifier: declineAction, title: "Not Now", options: [])
            ],
            intentIdentifiers: [])
    }

    /// Posts the page as a notification, so it reaches an operator in
    /// another app or another room. The banner in the window is the other
    /// half; whichever is used, the page goes from both.
    @MainActor
    static func post(_ page: TalkRouter.Page) {
        let request = UNNotificationRequest(
            identifier: page.id.uuidString,
            content: content(caller: page.caller, door: page.door, pageID: page.id),
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The page was answered, declined or ran out.
    @MainActor
    static func clear(_ page: TalkRouter.Page) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [page.id.uuidString])
        center.removePendingNotificationRequests(withIdentifiers: [page.id.uuidString])
    }

    /// A button on the notification: Answer or Not Now for the page, if it
    /// is still waiting. Tapping the notification itself only brings the
    /// app forward, where the banner is.
    @MainActor
    static func respond(_ action: String, pageID: UUID) {
        guard let router = SessionCoordinator.shared?.talkRouter,
              let page = router.pages.first(where: { $0.id == pageID }) else { return }
        switch action {
        case answerAction: router.answer(page)
        case declineAction: router.decline(page)
        default: break
        }
    }
}
