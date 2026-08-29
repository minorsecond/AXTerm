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
    /// Address book (nil when the database failed to open).
    let contactStore: ContactStore?
    /// Operator identity used to auto-fill forms and signatures.
    let profile: StationProfile
    /// App-wide position source (GPS with manual-grid fallback).
    let locationService: StationLocationService
    /// Replicates the mailbox to the operator's other devices. Nil when the
    /// database failed to open — no mailbox, nothing to share.
    let sync: WinlinkSyncController?

    /// Name of another of the operator's devices already using this callsign
    /// on this TNC, when one is known. Nil means clear.
    ///
    /// Read by the P2P listener, which must not answer an inbound call while
    /// a second station is answering to the same address — both would reply,
    /// with no operator present on either.
    @Published var contestedIdentityHolder: String?

    /// Inbox unread count for the sidebar badge; refreshed after
    /// exchanges and mailbox mutations.
    @Published private(set) var unreadCount: Int = 0

    /// How long a position fix stays good enough to stamp on a session
    /// log. A station that moved far enough to change what it can hear
    /// took longer than this to get there.
    private static let positionReuseWindow: TimeInterval = 600

    /// Publishes this station's directory for the operator's other stations.
    ///
    /// Refuses when sharing is off, so turning the setting off stops new
    /// observations leaving immediately rather than at the next launch.
    /// Already-published records are the sync engine's to retire.
    func publishLocalActivity(_ directory: [StationDirectoryEntry],
                              callsign: String,
                              now: Date = Date()) {
        guard settings.shareStationActivity, let activityStore else { return }
        activityStore.setLocalActivity(
            StationActivityPublication.payloads(
                from: directory,
                station: callsign,
                // The same per-install identity the transport publishes
                // under, so this station recognises its own echo and does
                // not re-import its own counts.
                deviceID: WinlinkSyncDevice.identifier(),
                gridSquare: settings.gridSquare,
                now: now))
    }

    /// Observations from the operator's other stations, kept apart from
    /// this station's own. Nil when the database could not open or the
    /// operator has not opted in.
    let activityStore: SQLiteStationActivityStore?

    init(store: WinlinkStore?, settings: WinlinkSettings, profile: StationProfile? = nil,
         contactStore: ContactStore? = nil,
         appSettings: AppSettingsStore? = nil,
         activityStore: SQLiteStationActivityStore? = nil) {
        self.activityStore = activityStore
        self.store = store
        self.contactStore = contactStore
        self.settings = settings
        let resolvedProfile = profile ?? StationProfile()
        self.profile = resolvedProfile
        let locationService = StationLocationService(
            manualGridProvider: { [weak settings] in settings?.gridSquare ?? "" })
        self.locationService = locationService
        // The operator's licence callsign and their ICS details live in
        // AppSettingsStore and StationProfile, not the mailbox — so the sync
        // engine is handed a way to reach them. Without it a second device
        // asks for a callsign it could have inherited.
        // No CloudKit under test mode. An isolated instance (the docker
        // rig) must never reach the operator's iCloud — UserDefaults and
        // the database can be redirected, but a shared cloud account
        // cannot, so sync is simply absent. (Found the hard way: a first
        // rig launch ran one sync pass before this guard existed.)
        self.sync = AppEnvironment.isTestMode ? nil : WinlinkSyncController.cloudKit(
            store: store as? WinlinkSyncStore,
            identityStore: appSettings.map {
                LiveIdentityStore(settings: $0, profile: resolvedProfile)
            },
            // The address book is about people, so it follows the operator
            // to every device they own.
            contactStore: contactStore,
            // Passed only when the operator has turned sharing on: the
            // source is then absent rather than present-and-idle, so
            // nothing is published and nothing arrives to store.
            activityStore: settings.shareStationActivity ? activityStore : nil,
            isEnabled: { [weak settings] in settings?.mailboxSyncEnabled ?? false })
        // Every exchange stamps its session log with where we were, so the
        // Stations list can say whether a stored measurement still applies
        // here. A fix from the last few minutes is reused rather than
        // waking CoreLocation once per gateway in a ladder run.
        self.runner = store.map { store in
            WinlinkSessionRunner(store: store) { [weak locationService] in
                guard let locationService else { return nil }
                if let last = locationService.lastLocation,
                   Date().timeIntervalSince(last.timestamp) < Self.positionReuseWindow {
                    return last
                }
                return await locationService.currentLocation()
            }
        }
        refreshUnread()
    }

    /// Built per call so an API-key change in Settings takes effect
    /// without restarting.
    func makeCMSClient() -> CMSClienting {
        WinlinkCMSClient(accessKey: settings.effectiveAPIKey)
    }

    /// Called when an exchange with a gateway or peer finishes.
    ///
    /// Distinct from `refreshUnread()`, which also fires on ordinary mailbox
    /// edits: the moment new mail actually crossed the air is the moment it
    /// is worth pushing to the operator's other devices, and syncing on
    /// every read flag instead would be chatty for no gain.
    func exchangeFinished() {
        refreshUnread()
        sync?.onSessionFinished()
    }

    /// App launch and every return to the foreground: pull whatever the
    /// other device did while this one was closed.
    func appBecameActive() {
        sync?.onForeground()
    }

    func refreshUnread() {
        // Crash recovery: an app death mid-exchange leaves messages stuck in
        // "sending" — requeue them so the next exchange picks them up (the
        // gateway declines duplicates by MID, so a double-send is harmless).
        try? store?.revertSendingToQueued()
        unreadCount = (try? store?.unreadInboxCount()) ?? 0
    }

    /// Link quality for the standalone map window, which has no view
    /// model to borrow from. Recomputed on demand — the session log is
    /// one row per exchange, so this is cheap.
    var mapLinkQuality: [String: WinlinkLinkQuality] {
        guard let store else { return [:] }
        let logs = (try? store.sessionLogs(limit: 2000)) ?? []
        return WinlinkLinkQuality.summarize(logs: logs, observer: nil)
    }
}
