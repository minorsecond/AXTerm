import Foundation
import Combine

/// Shared services for the Winlink feature, created once at app startup
/// and handed to the mail pane, the compose window, and Settings.
@MainActor
final class WinlinkContext: ObservableObject {

    /// Nil when the database failed to open (Winlink UI shows a notice).
    let store: WinlinkStore?
    let settings: WinlinkSettings
    let runner: WinlinkSessionRunner?

    /// Inbox unread count for the sidebar badge; refreshed after
    /// exchanges and mailbox mutations.
    @Published private(set) var unreadCount: Int = 0

    init(store: WinlinkStore?, settings: WinlinkSettings) {
        self.store = store
        self.settings = settings
        self.runner = store.map { WinlinkSessionRunner(store: $0) }
        refreshUnread()
    }

    /// Built per call so an API-key change in Settings takes effect
    /// without restarting.
    func makeCMSClient() -> CMSClienting {
        WinlinkCMSClient(accessKey: settings.effectiveAPIKey)
    }

    func refreshUnread() {
        unreadCount = (try? store?.unreadInboxCount()) ?? 0
    }
}
