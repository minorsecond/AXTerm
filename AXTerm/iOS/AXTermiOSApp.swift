#if os(iOS)
import SwiftUI

/// AXTerm on iPhone and iPad.
///
/// The same app, not a companion: it shares the AX.25 decoder, the Winlink
/// protocol stack, the store and the routing inference with the Mac, file for
/// file. What differs is the shell — a Mac has windows, menus and a pointer,
/// and a handheld has none of those — so the scene and the navigation are
/// written for this platform while everything underneath is the code the Mac
/// already runs.
///
/// The port is staged. This target currently builds the mail stack, the
/// stations and map surfaces, the stores and settings. The packet terminal,
/// the packet table and the analytics graph are still AppKit-bound on the
/// Mac and come across in later stages — see Docs/iOSPort.md for the list
/// and the order.
@main
struct AXTermiOSApp: App {

    @StateObject private var winlinkContext: WinlinkContext
    @StateObject private var settings: AppSettingsStore
    @StateObject private var client: PacketEngine
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let defaults = UserDefaults.standard
        let settingsStore = AppSettingsStore(defaults: defaults)

        // Started here too. Without it every Telemetry breadcrumb on iOS is a
        // no-op, so the handheld — the device most likely to be out of signal
        // and missing mail — was the one that could not be diagnosed. A radio
        // in the field is where a crash report matters most, not least.
        SentryManager.shared.startIfEnabled(settings: settingsStore)
        SentryManager.shared.addBreadcrumb(
            category: "app.lifecycle", message: "App init", level: .info, data: nil)

        let queue = try? DatabaseManager.makeDatabaseQueue()

        let packetStore = queue.map { SQLitePacketStore(dbQueue: $0) }
        let consoleStore = queue.map { SQLiteConsoleStore(dbQueue: $0) }
        let rawStore = queue.map { SQLiteRawStore(dbQueue: $0) }
        let eventStore = queue.map { SQLiteEventLogStore(dbQueue: $0) }
        let eventLogger = eventStore.map { DatabaseEventLogger(store: $0, settings: settingsStore) }

        _settings = StateObject(wrappedValue: settingsStore)
        _client = StateObject(wrappedValue: PacketEngine(
            settings: settingsStore,
            packetStore: packetStore,
            consoleStore: consoleStore,
            rawStore: rawStore,
            eventLogger: eventLogger,
            eventLogStore: eventStore,
            watchRecorder: eventStore.map { EventLogWatchRecorder(store: $0, settings: settingsStore) },
            notificationScheduler: UserNotificationScheduler(settings: settingsStore,
                                                             appState: DefaultAppStateProvider()),
            databaseWriter: queue))
        _winlinkContext = StateObject(wrappedValue: WinlinkContext(
            store: queue.map { SQLiteWinlinkStore(dbQueue: $0) },
            settings: WinlinkSettings(defaults: defaults),
            profile: StationProfile(defaults: defaults),
            contactStore: queue.map { SQLiteContactStore(dbQueue: $0) },
            appSettings: settingsStore,
            activityStore: queue.map { SQLiteStationActivityStore(dbQueue: $0) }))
    }

    var body: some Scene {
        WindowGroup {
            AXTermiOSRootView(context: winlinkContext, settings: settings, client: client)
                .environmentObject(winlinkContext)
                // Launch is not a scene-phase *change*: the phase is already
                // .active by the time the observer below is attached, so
                // onChange never fires for it. Without this, both of these
                // ran only after a trip to the background and back — the app
                // came up neither synced nor connected, and looked broken
                // until the operator happened to switch away and return.
                .task {
                    winlinkContext.appBecameActive()
                    reconnectIfWanted()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Coming back to the foreground is the moment the operator most
            // expects to see what their other radio did while this one was
            // in a pocket.
            winlinkContext.appBecameActive()
            reconnectIfWanted()
        }
    }

    /// Opens the link on launch and on every return to the foreground.
    ///
    /// On macOS this runs once at startup, because a Mac keeps its sockets.
    /// iOS suspends the app and drops the TCP connection to the TNC, so the
    /// same setting has to mean "and after every suspension" or it would work
    /// exactly once per launch and look broken thereafter.
    ///
    /// Skipped while a link is already up or being opened: a second attempt
    /// tears down the socket the first one is still establishing.
    private func reconnectIfWanted() {
        guard settings.autoConnectOnLaunch else { return }
        guard client.status != .connected, client.status != .connecting else { return }
        client.connectUsingSettings()
    }
}
#endif
