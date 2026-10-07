//
//  StationServices.swift
//  AXTerm
//
//  The station: the session coordinator, the mailbox and what they need,
//  built once at launch and run whether or not a window is open.
//
//  Smoke run 2026-10-03-1, issue 46: the main window built the coordinator
//  (which answers a SABM) and the mailbox, and ran the mailbox attach and
//  the service-address sync. A launch that restored no window, in test mode
//  or as a menu-bar station, heard callers and answered none. The window
//  now shows the station; it no longer is it.
//

#if os(macOS)
import AppKit
import Combine
import Foundation

@MainActor
final class StationServices {

    /// How many times any station has been built in this process. Read by
    /// tests; nothing else should care.
    private(set) static var buildCount = 0

    let coordinator: SessionCoordinator
    let bbsLibrary: BBSFileLibrary
    let callsignLookup: CallsignLookupService
    let bbsService: BBSService

    private let client: PacketEngine
    private let settings: AppSettingsStore
    private let winlinkContext: WinlinkContext
    private let bbsSettings: BBSSettings
    private let keepAwake: KeepAwakeController
    private var subscriptions = Set<AnyCancellable>()
    /// Answers inbound peer-to-peer Winlink calls when armed, with or
    /// without the Mail page open (smoke run issue 61).
    private var winlinkAnswerer: WinlinkP2PAnswerer?
    /// The inputs `syncServiceAddresses` last ran with.
    private var addressSignature = ""

    init(client: PacketEngine, settings: AppSettingsStore, winlinkContext: WinlinkContext,
         bbsSettings: BBSSettings, keepAwake: KeepAwakeController = .shared) {
        self.client = client
        self.settings = settings
        self.winlinkContext = winlinkContext
        self.bbsSettings = bbsSettings
        self.keepAwake = keepAwake
        let built = Self.build(client: client, settings: settings,
                               winlinkContext: winlinkContext, bbsSettings: bbsSettings)
        coordinator = built.coordinator
        bbsLibrary = built.bbsLibrary
        callsignLookup = built.callsignLookup
        bbsService = built.bbsService
        Self.buildCount += 1
        start()
    }

    // MARK: - Lifecycle

    /// What the window's first task used to do, and then the subscriptions
    /// that keep the station in step with settings and with what it is doing.
    private func start() {
        bbsService.attach()
        let answerer = WinlinkP2PAnswerer(coordinator: coordinator, context: winlinkContext,
                                          settings: settings, client: client)
        answerer.attach()
        winlinkAnswerer = answerer
        syncServiceAddresses()
        bbsLibrary.rescan()
        client.radioManager.startWatchingOutages()
        applyKeepAwake()

        // A settings object publishes before it changes, so its effects are
        // read on the next turn of the run loop, when the new value is in.
        Publishers.Merge3(settings.objectWillChange,
                          bbsSettings.objectWillChange,
                          winlinkContext.settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &subscriptions)

        // Keep-awake follows the radios and the sessions. The coordinator
        // publishes on every session event, transfers included, so this is
        // coalesced; the assertion only matters to the nearest moment.
        Publishers.Merge(client.radioManager.$radioStates.map { _ in () },
                         coordinator.objectWillChange.map { _ in () })
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in self?.applyKeepAwake() }
            .store(in: &subscriptions)

        // Saying goodbye costs one frame. Vanishing mid-session leaves the
        // caller's software retrying into an address that stopped existing,
        // with no way to tell that from a bad path. The sessions and radios
        // themselves are released by AXTermAppDelegate.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.bbsService.shutdown(reason: "AXTerm is closing") }
            .store(in: &subscriptions)
        SystemPowerMonitor.shared.willSleep
            .sink { [weak self] _ in self?.bbsService.shutdown(reason: "this station is going to sleep") }
            .store(in: &subscriptions)
        SystemPowerMonitor.shared.didWake
            .sink { [weak self] _ in
                guard let self else { return }
                self.bbsService.attach()
                self.syncServiceAddresses()
                self.applyKeepAwake()
            }
            .store(in: &subscriptions)
    }

    /// Ends the subscriptions. For tests; the app's station lives as long as
    /// the process.
    func stop() {
        subscriptions.removeAll()
    }

    private func settingsChanged() {
        if coordinator.localCallsign != settings.primaryCallsign {
            coordinator.applyLocalCallsign(settings.primaryCallsign)
        }
        if serviceAddressSignature != addressSignature {
            syncServiceAddresses()
        }
        applyKeepAwake()
    }

    // MARK: - Service addresses

    /// Every input deciding which addresses this station answers on, as one
    /// value.
    private var serviceAddressSignature: String {
        let winlink = winlinkContext.settings
        return [settings.primaryCallsign,
                bbsSettings.onAir ? "1" : "0",
                bbsSettings.callsign,
                winlink.p2pListenEnabled ? "1" : "0",
                winlink.p2pListenCallsign].joined(separator: "|")
    }

    /// Registers every address a service answers on with the session layer.
    ///
    /// Frames not addressed to a registered address never reach the session
    /// layer, so this is what makes a service SSID mean anything at all.
    func syncServiceAddresses() {
        addressSignature = serviceAddressSignature
        bbsService.syncServiceAddress()

        let winlink = winlinkContext.settings
        let address = winlink.p2pListenEnabled
            ? winlink.effectiveP2PCallsign(stationCallsign: settings.primaryCallsign)
            : ""
        coordinator.sessionManager.setServiceAddress(
            address.isEmpty ? nil : CallsignNormalizer.toAddress(address),
            for: "winlink.p2p")
    }

    // MARK: - Keep awake

    /// Re-evaluates the sleep and scheduling holds.
    private func applyKeepAwake() {
        let connected = client.radioManager.radioStates.values.contains(.connected)
        keepAwake.update(
            policy: settings.keepAwakePolicy,
            isConnected: connected,
            isTransferring: !coordinator.connectedSessions.isEmpty,
            // A node or mailbox that answers calls is armed even with nothing
            // in progress, and a station that sleeps stops answering.
            isListening: connected && (settings.netRomAcceptInbound || bbsSettings.onAir))
    }

    // MARK: - Building

    /// The shared session coordinator, wired to the engine, and the mailbox
    /// built around it. Until 2026-10-05 the main window built these when it
    /// was installed (`ContentView.makeServices`).
    private static func build(client: PacketEngine, settings: AppSettingsStore,
                                     winlinkContext: WinlinkContext,
                                     bbsSettings: BBSSettings) -> MainWindowServices {
        // Get or create the shared session coordinator so Settings can update the same instance.
        // Only seed @Published properties on a new coordinator — re-seeding an existing shared
        // instance during view init triggers "Publishing changes from within view updates".
        let coordinator: SessionCoordinator
        if let existing = SessionCoordinator.shared {
            coordinator = existing
            // This runs while SwiftUI installs the window, inside a view
            // update. It used to run on every settings edit as well, from
            // the initializer, and assigning the callsign unconditionally
            // there published `localCallsign` from inside the update: 36 of
            // the 61 warnings logged with the Settings window open on
            // 2026-09-29. With a window up, the onChange in
            // presentationLayer keeps the callsign in step; a change made
            // while no window was open catches up on the next turn of the
            // run loop, outside the update.
            if existing.localCallsign != settings.primaryCallsign {
                DispatchQueue.main.async { [weak existing, weak settings] in
                    guard let existing, let settings else { return }
                    existing.applyLocalCallsign(settings.primaryCallsign)
                }
            }
        } else {
            coordinator = SessionCoordinator()
            // Seed AXDP / transmission adaptive settings from persisted settings
            var adaptive = TxAdaptiveSettings()
            adaptive.axdpExtensionsEnabled = settings.axdpExtensionsEnabled
            adaptive.autoNegotiateCapabilities = settings.axdpAutoNegotiateCapabilities
            adaptive.compressionEnabled = settings.axdpCompressionEnabled
            if let algo = AXDPCompression.Algorithm(rawValue: settings.axdpCompressionAlgorithmRaw) {
                adaptive.compressionAlgorithm = algo
            }
            adaptive.maxDecompressedPayload = UInt32(settings.axdpMaxDecompressedPayload)
            adaptive.showAXDPDecodeDetails = settings.axdpShowDecodeDetails
            // The operator's manual PACLEN, K and N2, which were never kept
            // past a relaunch.
            adaptive = settings.ax25LinkTuning.applied(to: adaptive)
            coordinator.globalAdaptiveSettings = adaptive
            coordinator.adaptiveTransmissionEnabled = settings.adaptiveTransmissionEnabled
            coordinator.syncSessionManagerConfigFromAdaptive()
            if settings.adaptiveTransmissionEnabled {
                TxLog.adaptiveEnabled()
            } else {
                TxLog.adaptiveDisabled()
            }
            // The primary radio's address, SSID included; see
            // `SessionCoordinator.localCallsign`.
            coordinator.localCallsign = settings.primaryCallsign
            // Test mode: a command folder the smoke test drives transfers
            // and session text through (see TestCommandChannel).
            if TestModeConfiguration.shared.isTestMode,
               let folder = try? TestCommandChannel.folder(instanceID: TestModeConfiguration.shared.instanceID),
               let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                let channel = TestCommandChannel(folder: folder, coordinator: coordinator, filesFolder: downloads)
                channel.start()
                TestCommandChannel.running = channel
            }
        }
        // Also restores the NET/ROM node policy; see `appSettings`.
        coordinator.appSettings = settings
        // An APRS position beacon that follows the station reads the station
        // position at send time, from the same resolver the map uses.
        coordinator.aprsLocationProvider = StationPositionResolver.beaconProvider(
            defaults: settings.defaults, locationService: winlinkContext.locationService)
        coordinator.aprsLocationRefresh = { [weak service = winlinkContext.locationService] maxAge in
            _ = await service?.currentLocation(maxFixAge: maxAge)
        }
        coordinator.subscribeToPackets(from: client)
        // APRS messaging: wire the transmit funnel, the query-answer
        // providers, and start the ACK-retry sweep. Auto-reply defaults to
        // full (auto-ACK incoming messages and answer directed queries).
        if let aprs = client.aprsMessaging {
            aprs.autoReplyProvider = { APRSMessagingService.AutoReply(rawValue: settings.aprsAutoReplyRaw) ?? .full }
            aprs.send = { [weak coordinator] out in _ = coordinator?.sendAPRS(out) }
            aprs.positionInfo = { [weak coordinator] in coordinator?.currentAPRSPositionInfo() }
            aprs.heardDirect = { [weak client] in
                Array((client?.stations ?? []).filter { $0.lastVia.isEmpty }.map { $0.call }
                    .prefix(APRSMessagingService.directsStationLimit))
            }
            // Objects we own, most urgent first — `live()` already sorts
            // that way, and the cap in `objectAnswers` depends on it. Each is
            // rebuilt with the current time rather than replayed: see
            // `reannounced(at:)`.
            aprs.ownObjects = { [weak client, weak coordinator] in
                guard let client else { return [] }
                // The same set `mayRemove` uses: every address this station
                // answers to, not just the configured callsign. An object
                // placed from a second radio's SSID is still ours.
                let answered = Set((coordinator?.sessionManager.answeredAddresses ?? [])
                    .map { $0.display.uppercased() })
                let ours = answered.isEmpty ? Array(settings.onAirCallsigns) : Array(answered)
                let oursSet = Set(ours)
                let asOf = Date()
                return client.aprsObjects.live()
                    .filter { oursSet.contains($0.reportedBy.uppercased()) }
                    .compactMap { $0.report.reannounced(at: asOf) }
            }
            aprs.versionInfo = {
                let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                return v.isEmpty ? "AXTerm" : "AXTerm \(v)"
            }
            aprs.startRetryTimer()
        }
        // "Who can hear me": flood one unaddressed ?APRS? general query and
        // fold in whoever answers (real APRS stations only, never packet
        // nodes). Xastir-style — one transmission, not a directed poll.
        let probe = client.aprsProbe
        probe.aprsStations = { [weak client] in client?.aprsHeardStations() ?? [] }
        // Sampled when a query goes out, so the results can tell an answer
        // from a station that beacons often enough to land in any window.
        probe.beaconIntervals = { [weak client] in client?.aprsBeaconIntervals() ?? [:] }
        probe.floodQuery = { [weak coordinator] query, reach in
            (coordinator?.floodAPRS(query.rawValue, reach: reach) ?? 0) > 0
        }
        // A queued send has already reported success by the time a radio fails
        // to key, so the probe hears about that the only way it can: a link
        // fault arriving while it is listening.
        client.onLinkError = { [weak probe] message in probe?.transmitDidFail(message) }
        // The personal mailbox. Built here because this is the one place that
        // holds both the coordinator (which owns inbound calls) and the engine
        // (which owns the database and the frame sink).
        // Hoisted rather than inlined: as one expression the closures push the
        // type checker past its budget.
        let sendFrames: ([OutboundFrame]) -> Void = { [weak client] frames in
            for frame in frames { client?.send(frame: frame) }
        }
        // What an empty mailbox or P2P callsign falls back to: the address
        // the primary radio answers as, which is what the station callsign
        // was before SSIDs moved to the radios. The bare base call would be
        // a new address that no radio operates under.
        let stationCallsign: () -> String = { settings.primaryCallsign }
        let winlinkArmed: () -> Bool = { winlinkContext.settings.p2pListenEnabled }
        let winlinkCallsign: () -> String = {
            winlinkContext.settings.effectiveP2PCallsign(stationCallsign: settings.primaryCallsign)
        }
        let contested: () -> String? = { winlinkContext.contestedIdentityHolder }
        let library = BBSFileLibrary(store: client.bbsMessages)
        let supportsAXDP: (String) -> Bool = { [weak client] callsign in
            client?.capabilityStore.hasCapabilities(for: callsign) ?? false
        }
        // Built before the mailbox so the mailbox can read its cache.
        let lookup = CallsignLookupService(
            store: winlinkContext.store,
            isNetworkEnabled: winlinkContext.settings.callsignLookupEnabled)
        // Cached only: the mailbox answers calls unattended, and looking a
        // caller up over the internet the moment they connect would tell a
        // third party who is talking to this station.
        let licence: (String) -> CallsignRecord? = { [weak lookup] callsign in
            lookup?.cached(callsign)
        }
        let heard: () -> [BBSShell.HeardStation] = { [weak client] in
            (client?.stations ?? []).compactMap { station in
                guard let lastHeard = station.lastHeard else { return nil }
                return BBSShell.HeardStation(callsign: station.call, lastHeard: lastHeard)
            }
        }
        let bbsService = BBSService(
            store: client.bbsMessages,
            settings: bbsSettings,
            coordinator: coordinator,
            sendFrames: sendFrames,
            stationCallsign: stationCallsign,
            isWinlinkP2PArmed: winlinkArmed,
            winlinkP2PCallsign: winlinkCallsign,
            heardStations: heard,
            library: library,
            peerSupportsAXDP: supportsAXDP,
            licenceRecord: licence,
            announce: { [weak client] line in client?.appendSystemNotification(line) },
            resolveLicences: { [weak lookup] callsigns in await lookup?.resolveAll(callsigns) },
            contestedIdentityHolder: contested)
        return MainWindowServices(coordinator: coordinator, bbsLibrary: library,
                                  callsignLookup: lookup, bbsService: bbsService)
    }

}
#endif
