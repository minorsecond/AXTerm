//
//  AppSettingsStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation
import Combine

final class AppSettingsStore: ObservableObject {
    private static var testRetainedStores: [AppSettingsStore] = []
    static let hostKey = "lastHost"
    static let portKey = "lastPort"
    static let retentionKey = "retentionLimit"
    static let consoleRetentionKey = "consoleRetentionLimit"
    static let rawRetentionKey = "rawRetentionLimit"
    static let eventRetentionKey = "eventRetentionLimit"
    static let retentionDurationKey = "retentionDuration"
    static let persistKey = "persistHistory"
    static let consoleSeparatorsKey = "consoleDaySeparators"
    static let rawSeparatorsKey = "rawDaySeparators"
    static let runInMenuBarKey = "runInMenuBar"
    static let launchAtLoginKey = "launchAtLogin"
    static let autoConnectKey = "autoConnectOnLaunch"
    static let notifyOnWatchKey = "notifyOnWatchHits"
    static let notifyOnNodeMailKey = "notifyOnNodeMail"
    static let notifyOnInboundConnectionKey = "notifyOnInboundConnection"
    static let notifyOnMentionKey = "notifyOnMention"
    static let notifyPlaySoundKey = "notifyPlaySound"
    static let notifyOnlyWhenInactiveKey = "notifyOnlyWhenInactive"
    static let myCallsignKey = "myCallsign"
    static let watchCallsignsKey = "watchCallsigns"
    static let watchKeywordsKey = "watchKeywords"
    static let ignoredServiceEndpointsKey = "ignoredServiceEndpoints"
    static let sentryEnabledKey = "sentryEnabled"
    static let sentrySendPacketContentsKey = "sentrySendPacketContents"
    static let sentrySendConnectionDetailsKey = "sentrySendConnectionDetails"

    // Serial transport settings keys
    static let transportTypeKey = "kissTransportType"
    static let serialDevicePathKey = "serialDevicePath"
    static let serialBaudRateKey = "serialBaudRate"
    static let serialAutoReconnectKey = "serialAutoReconnect"

    // BLE transport settings keys
    static let blePeripheralUUIDKey = "blePeripheralUUID"
    static let blePeripheralNameKey = "blePeripheralName"
    static let bleAutoReconnectKey = "bleAutoReconnect"

    // Mobilinkd TNC4 settings keys
    static let mobilinkdEnabledKey = "mobilinkdEnabled"
    static let mobilinkdModemTypeKey = "mobilinkdModemType"
    static let mobilinkdOutputGainKey = "mobilinkdOutputGain"
    static let mobilinkdInputGainKey = "mobilinkdInputGain_v3"

    // File transfer settings keys
    static let allowedFileTransferCallsignsKey = "allowedFileTransferCallsigns"
    static let deniedFileTransferCallsignsKey = "deniedFileTransferCallsigns"

    // Analytics settings keys
    static let analyticsTimeframeKey = "analyticsTimeframe"
    static let analyticsBucketKey = "analyticsBucket"
    static let analyticsIncludeViaKey = "analyticsIncludeVia"
    static let analyticsMinEdgeCountKey = "analyticsMinEdgeCount"
    static let analyticsMaxNodesKey = "analyticsMaxNodes"
    static let analyticsHubMetricKey = "analyticsHubMetric"
    static let analyticsStationIdentityModeKey = "analyticsStationIdentityMode"
    static let analyticsAutoUpdateEnabledKey = "analyticsAutoUpdateEnabled"
    static let ax25NegotiateV22Key = "ax25NegotiateV22"

    // AXDP / transmission extension settings keys
    static let axdpExtensionsEnabledKey = "axdpExtensionsEnabled"
    static let netRomAdvertiseKey = "netRomAdvertiseSelf"
    static let netRomForwardingKey = "netRomForwarding"
    static let netRomNodeAliasKey = "netRomNodeAlias"
    static let netRomBroadcastMinutesKey = "netRomBroadcastMinutes"

    /// Announcing this station and carrying other people's traffic both
    /// default OFF. Each changes what other operators' nodes do, so each
    /// is the operator's deliberate decision, not an app upgrade's.
    static let defaultNetRomAdvertise = false
    static let defaultNetRomForwarding = false
    /// BPQ's NODESINTERVAL is 60 minutes; that is the neighbourly rate.
    static let defaultNetRomBroadcastMinutes = 60

    // Beacon: what this station says about itself, unprompted.
    static let beaconEnabledKey = "beaconEnabled"
    static let autoRouteMaxChainLengthKey = "autoRouteMaxChainLength"
    static let netRomAcceptInboundKey = "netRomAcceptInbound"
    static let digipeatEnabledKey = "digipeatEnabled"
    static let digipeatAliasKey = "digipeatAlias"
    static let terminalFontSizeKey = "terminalFontSize"
    static let beaconTextKey = "beaconText"
    static let beaconMinutesKey = "beaconMinutes"
    static let beaconPathKey = "beaconPath"

    /// Off, and empty. A beacon is the operator's own words going out
    /// over their licence; there is no default worth putting on the air
    /// on their behalf.
    static let defaultBeaconEnabled = false
    /// Thirty minutes. Node beacons on a shared channel run anywhere from
    /// ten to sixty; this errs toward the quiet end.
    static let defaultBeaconMinutes = 30

    // Ping: asking stations whether they can hear us.
    static let pingEnabledKey = "pingEnabled"
    static let pingWindowStartKey = "pingWindowStartHour"
    static let pingWindowEndKey = "pingWindowEndHour"
    static let pingSpacingKey = "pingMinSecondsBetween"
    static let pingCooldownKey = "pingStationCooldownMinutes"
    static let pingMaxPerHourKey = "pingMaxProbesPerHour"
    static let pingProbeCalledKey = "pingProbeStationsOthersCall"

    /// Off. Automatic transmission on a shared channel is the operator's
    /// decision every time, and the defaults below are deliberately timid.
    static let defaultPingEnabled = false
    static let axdpAutoNegotiateKey = "axdpAutoNegotiateCapabilities"
    static let axdpCompressionEnabledKey = "axdpCompressionEnabled"
    static let axdpCompressionAlgorithmKey = "axdpCompressionAlgorithm"
    static let axdpMaxDecompressedPayloadKey = "axdpMaxDecompressedPayload"
    static let axdpShowDecodeDetailsKey = "axdpShowAXDPDecodeDetails"
    static let adaptiveTransmissionEnabledKey = "adaptiveTransmissionEnabled"
    static let ax25T1TimeoutSecondsKey = "ax25T1TimeoutSeconds"
    static let tncCapabilitiesKey = "tncCapabilities"

    // NET/ROM route settings keys
    static let hideExpiredRoutesKey = "hideExpiredRoutes"
    static let routeRetentionDaysKey = "routeRetentionDays"
    static let stalePolicyModeKey = "stalePolicyMode"
    static let globalStaleTTLHoursKey = "globalStaleTTLHours"
    static let adaptiveStaleMissedBroadcastsKey = "adaptiveStaleMissedBroadcasts"
    static let neighborStaleTTLHoursKey = "neighborStaleTTLHours"
    static let linkStatStaleTTLHoursKey = "linkStatStaleTTLHours"

    static let defaultTransportType = "network"
    static let defaultSerialDevicePath = ""
    static let defaultSerialBaudRate = 115200
    static let defaultSerialAutoReconnect = true

    static let defaultBLEPeripheralUUID = ""
    static let defaultBLEPeripheralName = ""
    static let defaultBLEAutoReconnect = true

    static let defaultMobilinkdEnabled = false
    static let defaultMobilinkdModemType = 1 // 1200 baud
    static let defaultMobilinkdOutputGain = 11   // TNC4 factory default
    static let defaultMobilinkdInputGain = 0     // TNC4 factory default


    static let defaultHost = "localhost"
    static let defaultPort = 8001
    static let defaultRetention = 50_000
    static let minRetention = 1_000

    static let maxRetention = 10_000_000 // 10M packets (~3 years of heavy usage)
    
    // Size estimation constants
    static let estimatedBytesPerPacket = 400
    static let estimatedBytesPerConsoleLine = 200
    static let estimatedBytesPerRawChunk = 100
    
    // Default ingestion rates for time-based mapping
    // Assuming heavy usage: ~10k packets/day
    static let estimatedPacketsPerDay = 10_000
    static let estimatedConsoleLinesPerDay = 2_000 
    static let estimatedRawChunksPerDay = 2_000

    enum HistoryRetentionDuration: String, CaseIterable, Identifiable {
        case oneDay = "1 Day"
        case sevenDays = "7 Days"
        case thirtyDays = "30 Days"
        case ninetyDays = "90 Days"
        case oneYear = "1 Year"
        case forever = "Forever"
        case custom = "Custom"
        
        var id: String { rawValue }
        
        // Maps duration to Packet retention limit
        var packetLimit: Int {
            switch self {
            case .oneDay: return AppSettingsStore.estimatedPacketsPerDay
            case .sevenDays: return AppSettingsStore.estimatedPacketsPerDay * 7
            case .thirtyDays: return AppSettingsStore.estimatedPacketsPerDay * 30
            case .ninetyDays: return AppSettingsStore.estimatedPacketsPerDay * 90
            case .oneYear: return AppSettingsStore.estimatedPacketsPerDay * 365
            case .forever: return Int.max
            case .custom: return AppSettingsStore.defaultRetention // Fallback, usually ignored
            }
        }
        
        // Maps duration to Console/Raw/Event retention limit (using same scale for simplicity, or adjusted)
        var logLimit: Int {
            switch self {
            case .oneDay: return AppSettingsStore.estimatedConsoleLinesPerDay
            case .sevenDays: return AppSettingsStore.estimatedConsoleLinesPerDay * 7
            case .thirtyDays: return AppSettingsStore.estimatedConsoleLinesPerDay * 30
            case .ninetyDays: return AppSettingsStore.estimatedConsoleLinesPerDay * 90
            case .oneYear: return AppSettingsStore.estimatedConsoleLinesPerDay * 365
            case .forever: return Int.max
            case .custom: return AppSettingsStore.defaultConsoleRetention
            }
        }
    }
    
    static let defaultRetentionDuration: HistoryRetentionDuration = .sevenDays

    static let defaultConsoleRetention = 10_000
    static let defaultRawRetention = 10_000
    static let defaultEventRetention = 10_000
    static let minLogRetention = 1_000
    static let maxLogRetention = 2_000_000
    static let defaultConsoleSeparators = true
    static let defaultRawSeparators = false
    static let defaultRunInMenuBar = false
    static let defaultLaunchAtLogin = false
    static let defaultAutoConnect = false
    static let defaultNotifyOnWatch = true
    static let defaultNotifyOnNodeMail = true
    static let defaultNotifyOnInboundConnection = true
    static let defaultNotifyOnMention = true
    static let defaultNotifyPlaySound = true
    static let defaultNotifyOnlyWhenInactive = true
    static let defaultIgnoredServiceEndpoints: [String] = []
    static let defaultSentryEnabled = false
    static let defaultSentrySendPacketContents = false
    static let defaultSentrySendConnectionDetails = false

    // Analytics defaults (packet-radio optimized)
    static let defaultAnalyticsTimeframe = "twentyFourHours"  // 24h captures daily activity patterns
    static let defaultAnalyticsBucket = "auto"
    static let defaultAnalyticsIncludeVia = true  // Digipeater paths are essential for packet networks
    static let defaultAnalyticsMinEdgeCount = 2   // Filters single-packet noise
    static let defaultAnalyticsMaxNodes = 150
    static let defaultAnalyticsHubMetric = "Degree"  // Matches HubMetric.degree.rawValue
    static let defaultAnalyticsStationIdentityMode = "station"  // Group SSIDs by default
    static let defaultAnalyticsAutoUpdateEnabled = true
    /// AX.25 2.2 XID negotiation (SREJ + parameter limits) before the
    /// first SABM to an unknown station. Default on: 2.2 peers answer,
    /// pre-2.2 peers answer FRMR (the spec's "use defaults"), and a
    /// silent peer costs one RTO exactly once per callsign.
    static let defaultAX25NegotiateV22 = true

    // AXDP defaults (match TxAdaptiveSettings defaults)
    static let defaultAXDPExtensionsEnabled = true
    static let defaultAXDPAutoNegotiate = false
    static let defaultAXDPCompressionEnabled = true
    static let defaultAXDPCompressionAlgorithm: UInt8 = 1  // AXDPCompression.Algorithm.lz4
    static let defaultAXDPMaxDecompressedPayload = 4096
    static let defaultAXDPShowDecodeDetails = false
    static let defaultAdaptiveTransmissionEnabled = true
    static let defaultAX25T1TimeoutSeconds = 4.0
    static let minAX25T1TimeoutSeconds = 1.0
    static let maxAX25T1TimeoutSeconds = 30.0

    // NET/ROM route defaults
    static let defaultHideExpiredRoutes = true  // Hide expired routes by default for clean UI
    static let defaultRouteRetentionDays = 60   // Keep routes for 60 days before pruning
    static let minRouteRetentionDays = 1
    static let maxRouteRetentionDays = 365
    static let defaultStalePolicyMode = "adaptive"  // Use adaptive per-origin by default
    static let defaultGlobalStaleTTLHours = 1   // 1 hour = 60 minutes (matches default freshness TTL of 30 min)
    static let minGlobalStaleTTLHours = 1
    static let maxGlobalStaleTTLHours = 168     // 1 week max
    static let defaultAdaptiveStaleMissedBroadcasts = 3  // Consider stale after missing 3 expected broadcasts
    static let minAdaptiveStaleMissedBroadcasts = 2
    static let maxAdaptiveStaleMissedBroadcasts = 10

    // Neighbor activity decay TTL (separate from route adaptive)
    static let defaultNeighborStaleTTLHours = 6  // Neighbors stale after 6 hours of no activity
    static let minNeighborStaleTTLHours = 1
    static let maxNeighborStaleTTLHours = 168    // 1 week max

    // Link stat activity decay TTL (separate from route adaptive)
    static let defaultLinkStatStaleTTLHours = 12  // Link stats stale after 12 hours of no activity
    static let minLinkStatStaleTTLHours = 1
    static let maxLinkStatStaleTTLHours = 168     // 1 week max

    // Clear timestamp keys for views
    static let terminalClearedAtKey = "terminalClearedAt"
    static let consoleClearedAtKey = "consoleClearedAt"
    static let rawClearedAtKey = "rawClearedAt"

    @Published var host: String {
        didSet {
            let sanitized = Self.sanitizeHost(host)
            guard sanitized == host else {
                deferUpdate { [weak self, sanitized] in
                    self?.host = sanitized
                }
                return
            }
            persistHost()
        }
    }

    @Published var port: Int {
        didSet {
            let sanitized = Self.sanitizePort(port)
            guard sanitized == port else {
                deferUpdate { [weak self, sanitized] in
                    self?.port = sanitized
                }
                return
            }
            persistPort()
        }
    }

    @Published var retentionLimit: Int {
        didSet {
            let sanitized = Self.sanitizeRetention(retentionLimit)
            guard sanitized == retentionLimit else {
                deferUpdate { [weak self, sanitized] in
                    self?.retentionLimit = sanitized
                }
                return
            }
            if retentionDuration != .custom && retentionDuration.packetLimit != retentionLimit {
                retentionDuration = .custom
            }
            persistRetention()
        }
    }

    @Published var consoleRetentionLimit: Int {
        didSet {
            let sanitized = Self.sanitizeLogRetention(consoleRetentionLimit)
            guard sanitized == consoleRetentionLimit else {
                deferUpdate { [weak self, sanitized] in
                    self?.consoleRetentionLimit = sanitized
                }
                return
            }
            if retentionDuration != .custom && retentionDuration.logLimit != consoleRetentionLimit {
                retentionDuration = .custom
            }
            persistConsoleRetention()
        }
    }

    @Published var rawRetentionLimit: Int {
        didSet {
            let sanitized = Self.sanitizeLogRetention(rawRetentionLimit)
            guard sanitized == rawRetentionLimit else {
                deferUpdate { [weak self, sanitized] in
                    self?.rawRetentionLimit = sanitized
                }
                return
            }
            if retentionDuration != .custom && retentionDuration.logLimit != rawRetentionLimit {
                retentionDuration = .custom
            }
            persistRawRetention()
        }
    }

    @Published var eventRetentionLimit: Int {
        didSet {
            let sanitized = Self.sanitizeLogRetention(eventRetentionLimit)
            guard sanitized == eventRetentionLimit else {
                deferUpdate { [weak self, sanitized] in
                    self?.eventRetentionLimit = sanitized
                }
                return
            }
            persistEventRetention()
        }
    }

    @Published var retentionDuration: HistoryRetentionDuration {
        didSet {
            if retentionDuration != .custom {
                // Apply presets
                let newPacketLimit = retentionDuration.packetLimit
                let newLogLimit = retentionDuration.logLimit
                
                if retentionLimit != newPacketLimit { retentionLimit = newPacketLimit }
                if consoleRetentionLimit != newLogLimit { consoleRetentionLimit = newLogLimit }
                if rawRetentionLimit != newLogLimit { rawRetentionLimit = newLogLimit }
                // Event retention is managed separately
            }
            persistRetentionDuration()
        }
    }

    @Published var persistHistory: Bool {
        didSet { persistPersistHistory() }
    }

    @Published var showConsoleDaySeparators: Bool {
        didSet { persistConsoleSeparators() }
    }

    @Published var showRawDaySeparators: Bool {
        didSet { persistRawSeparators() }
    }

    /// `runInMenuBar` is NOT @Published to avoid feedback loops with MenuBarExtra(isInserted:).
    /// The App scene uses @AppStorage directly; this computed property is for SettingsView only.
    var runInMenuBar: Bool {
        get { defaults.object(forKey: Self.runInMenuBarKey) as? Bool ?? Self.defaultRunInMenuBar }
        set { defaults.set(newValue, forKey: Self.runInMenuBarKey) }
    }

    @Published var launchAtLogin: Bool {
        didSet { persistLaunchAtLogin() }
    }

    @Published var autoConnectOnLaunch: Bool {
        didSet { persistAutoConnect() }
    }

    // MARK: - Serial Transport Settings

    @Published var transportType: String {
        didSet { persistTransportType() }
    }

    @Published var serialDevicePath: String {
        didSet { persistSerialDevicePath() }
    }

    @Published var serialBaudRate: Int {
        didSet {
            let clamped = Self.commonBaudRates.contains(serialBaudRate) ? serialBaudRate : Self.defaultSerialBaudRate
            guard clamped == serialBaudRate else {
                deferUpdate { [weak self, clamped] in
                    self?.serialBaudRate = clamped
                }
                return
            }
            persistSerialBaudRate()
        }
    }

    @Published var serialAutoReconnect: Bool {
        didSet { persistSerialAutoReconnect() }
    }

    /// Common baud rates for KISS TNCs
    static let commonBaudRates = [1200, 9600, 19200, 38400, 57600, 115200, 230400]

    /// Whether the current transport type is serial
    var isSerialTransport: Bool {
        transportType == "serial"
    }

    // MARK: - BLE Transport Settings

    @Published var blePeripheralUUID: String {
        didSet { persistBLEPeripheralUUID() }
    }

    @Published var blePeripheralName: String {
        didSet { persistBLEPeripheralName() }
    }

    @Published var bleAutoReconnect: Bool {
        didSet { persistBLEAutoReconnect() }
    }

    /// Whether the current transport type is BLE
    var isBLETransport: Bool {
        transportType == "ble"
    }

    // MARK: - Mobilinkd Settings

    @Published var mobilinkdEnabled: Bool {
        didSet { persistMobilinkdEnabled() }
    }

    @Published var mobilinkdModemType: Int {
        didSet { persistMobilinkdModemType() }
    }

    @Published var mobilinkdOutputGain: Int {
        didSet { persistMobilinkdOutputGain() }
    }

    @Published var mobilinkdInputGain: Int {
        didSet { persistMobilinkdInputGain() }
    }

    @Published var notifyOnWatchHits: Bool {
        didSet { persistNotifyOnWatch() }
    }

    @Published var notifyOnNodeMail: Bool {
        didSet { persistNotifyOnNodeMail() }
    }

    @Published var notifyOnInboundConnection: Bool {
        didSet { persistNotifyOnInboundConnection() }
    }

    @Published var notifyOnMention: Bool {
        didSet { persistNotifyOnMention() }
    }

    @Published var notifyPlaySound: Bool {
        didSet { persistNotifyPlaySound() }
    }

    @Published var notifyOnlyWhenInactive: Bool {
        didSet { persistNotifyOnlyWhenInactive() }
    }

    static let keepAwakePolicyKey = "keepAwakePolicy"

    /// Whether the app holds the screen on, and when. iOS only — a Mac's
    /// display sleeping does not suspend the app or drop its sockets.
    ///
    /// Defaults to holding only during transfers: that is the case where
    /// sleeping actually costs something, and holding it permanently would
    /// flatten a battery the operator may need for other things.
    @Published var keepAwakePolicy: KeepAwakePolicy {
        didSet { defaults.set(keepAwakePolicy.rawValue, forKey: Self.keepAwakePolicyKey) }
    }

    @Published private var myCallsignStorage: String

    var myCallsign: String {
        get { myCallsignStorage }
        set {
            let sanitized = CallsignValidator.normalize(newValue)
            guard sanitized != myCallsignStorage else { return }
            myCallsignStorage = sanitized
            persistMyCallsign()
        }
    }

    @Published var watchCallsigns: [String] {
        didSet {
            persistWatchCallsigns()
        }
    }

    @Published var watchKeywords: [String] {
        didSet {
            persistWatchKeywords()
        }
    }

    @Published var ignoredServiceEndpoints: [String] {
        didSet {
            let sanitized = Self.sanitizeWatchList(ignoredServiceEndpoints, normalize: CallsignValidator.normalize)
            guard sanitized == ignoredServiceEndpoints else {
                ignoredServiceEndpoints = sanitized
                return
            }
            CallsignValidator.configureIgnoredServiceEndpoints(sanitized)
            persistIgnoredServiceEndpoints()
        }
    }

    @Published var sentryEnabled: Bool {
        didSet { persistSentryEnabled() }
    }

    @Published var sentrySendPacketContents: Bool {
        didSet { persistSentrySendPacketContents() }
    }

    @Published var sentrySendConnectionDetails: Bool {
        didSet { persistSentrySendConnectionDetails() }
    }

    // MARK: - AXDP / Transmission Extension Settings

    /// Whether AXDP extensions are enabled globally.
    @Published var axdpExtensionsEnabled: Bool {
        didSet { persistAXDPExtensionsEnabled() }
    }

    // MARK: - NET/ROM node settings

    /// Announce this station in NODES broadcasts, so neighbors learn it
    /// exists and can route to it. Off by default: this writes AXTerm
    /// into other operators' routing tables.
    @Published var netRomAdvertiseSelf: Bool {
        didSet { defaults.set(netRomAdvertiseSelf, forKey: Self.netRomAdvertiseKey) }
    }

    /// Carry other stations' NET/ROM traffic. Off by default: transit
    /// routing spends this station's airtime on other people's packets
    /// and makes it answerable for delivering them.
    @Published var netRomForwarding: Bool {
        didSet { defaults.set(netRomForwarding, forKey: Self.netRomForwardingKey) }
    }

    /// Six-character node alias (BPQ's NODEALIAS). Empty means the
    /// station announces with a blank mnemonic, which is legal but
    /// unfriendly, so the UI should ask for one before enabling
    /// announcements.
    @Published var netRomNodeAlias: String {
        didSet { defaults.set(netRomNodeAlias, forKey: Self.netRomNodeAliasKey) }
    }

    /// Minutes between NODES broadcasts.
    @Published var netRomBroadcastMinutes: Int {
        didSet { defaults.set(netRomBroadcastMinutes, forKey: Self.netRomBroadcastMinutesKey) }
    }

    // MARK: - Beacon

    /// Transmit a periodic unconnected announcement. Off by default.
    @Published var beaconEnabled: Bool {
        didSet { defaults.set(beaconEnabled, forKey: Self.beaconEnabledKey) }
    }

    /// Repeat frames addressed via this station. Off by default: a
    /// digipeater volunteers this transmitter for other people\u{2019}s
    /// traffic on every frame that names it.
    @Published var digipeatEnabled: Bool {
        didSet { defaults.set(digipeatEnabled, forKey: Self.digipeatEnabledKey) }
    }

    /// An additional name the digipeater answers to (like DWARC), or
    /// empty for the station callsign only.
    @Published var digipeatAlias: String {
        didSet { defaults.set(digipeatAlias, forKey: Self.digipeatAliasKey) }
    }

    /// Answer inbound NET/ROM circuits with the node shell. Off by
    /// default like every on-air switch: accepting circuits commits
    /// this transmitter to serving other people\u{2019}s sessions.
    @Published var netRomAcceptInbound: Bool {
        didSet { defaults.set(netRomAcceptInbound, forKey: Self.netRomAcceptInboundKey) }
    }

    /// How many nodes the Auto ladder may chain through. An operator's
    /// airtime judgment, not ours: a four-hop prompt relay can hold the
    /// channel for minutes, and courtesy differs by channel.
    @Published var autoRouteMaxChainLength: Int {
        didSet {
            let clamped = min(6, max(1, autoRouteMaxChainLength))
            if clamped != autoRouteMaxChainLength { autoRouteMaxChainLength = clamped; return }
            defaults.set(autoRouteMaxChainLength, forKey: Self.autoRouteMaxChainLengthKey)
        }
    }

    /// Terminal console text size. A packet terminal is stared at for
    /// hours, in the field, at 2 AM — eleven points is not everyone's
    /// eleven points.
    @Published var terminalFontSize: Double {
        didSet {
            let clamped = min(18, max(9, terminalFontSize))
            if clamped != terminalFontSize { terminalFontSize = clamped; return }
            defaults.set(terminalFontSize, forKey: Self.terminalFontSizeKey)
        }
    }

    /// What the beacon says. The operator's own words, sent under their
    /// callsign — nothing here writes it for them.
    @Published var beaconText: String {
        didSet { defaults.set(beaconText, forKey: Self.beaconTextKey) }
    }

    /// Minutes between beacons.
    @Published var beaconMinutes: Int {
        didSet { defaults.set(beaconMinutes, forKey: Self.beaconMinutesKey) }
    }

    /// Digipeaters to send the beacon through, as typed: `WIDE1-1`,
    /// `DRL WIDE2-1`, `DRL,WIDE2-1`. Empty means direct.
    ///
    /// A beacon is exactly the traffic worth digipeating — its whole
    /// purpose is to reach stations that cannot hear this one. The NODES
    /// broadcast is the opposite case and stays direct; see
    /// `SessionCoordinator.scheduleNetRomBroadcasts`.
    @Published var beaconPath: String {
        didSet { defaults.set(beaconPath, forKey: Self.beaconPathKey) }
    }

    // MARK: - Ping

    @Published var pingEnabled: Bool {
        didSet { defaults.set(pingEnabled, forKey: Self.pingEnabledKey) }
    }
    @Published var pingWindowStartHour: Int {
        didSet { defaults.set(pingWindowStartHour, forKey: Self.pingWindowStartKey) }
    }
    @Published var pingWindowEndHour: Int {
        didSet { defaults.set(pingWindowEndHour, forKey: Self.pingWindowEndKey) }
    }
    @Published var pingMinSecondsBetween: Int {
        didSet { defaults.set(pingMinSecondsBetween, forKey: Self.pingSpacingKey) }
    }
    @Published var pingStationCooldownMinutes: Int {
        didSet { defaults.set(pingStationCooldownMinutes, forKey: Self.pingCooldownKey) }
    }
    @Published var pingMaxProbesPerHour: Int {
        didSet { defaults.set(pingMaxProbesPerHour, forKey: Self.pingMaxPerHourKey) }
    }
    /// Probe stations this receiver has never heard, but that neighbours
    /// were heard calling. Off by default: a blind call to a station that
    /// may be a hundred miles away is a transmission for a low chance of
    /// an answer.
    @Published var pingProbeStationsOthersCall: Bool {
        didSet { defaults.set(pingProbeStationsOthersCall, forKey: Self.pingProbeCalledKey) }
    }

    /// The settings model the policy actually reads.
    var pingPolicySettings: PingPolicy.Settings {
        var sources: Set<PingPolicy.Source> = [.heardDirect]
        if pingProbeStationsOthersCall { sources.insert(.calledByOthers) }
        return PingPolicy.Settings(
            enabled: pingEnabled,
            windowStartHour: pingWindowStartHour,
            windowEndHour: pingWindowEndHour,
            minSecondsBetweenProbes: pingMinSecondsBetween,
            stationCooldownMinutes: pingStationCooldownMinutes,
            maxProbesPerHour: pingMaxProbesPerHour,
            sources: sources)
    }

    /// Whether to automatically negotiate AXDP capabilities on connect.
    @Published var axdpAutoNegotiateCapabilities: Bool {
        didSet { persistAXDPAutoNegotiateCapabilities() }
    }

    /// Whether AXDP compression is enabled for AXTerm peers.
    @Published var axdpCompressionEnabled: Bool {
        didSet { persistAXDPCompressionEnabled() }
    }

    /// Preferred AXDP compression algorithm (raw value, mapped to enum elsewhere).
    @Published var axdpCompressionAlgorithmRaw: UInt8 {
        didSet { persistAXDPCompressionAlgorithm() }
    }

    /// Maximum allowed decompressed AXDP payload size (bytes).
    @Published var axdpMaxDecompressedPayload: Int {
        didSet { persistAXDPMaxDecompressedPayload() }
    }

    /// Whether to show detailed AXDP decode information in the transcript.
    @Published var axdpShowDecodeDetails: Bool {
        didSet { persistAXDPShowDecodeDetails() }
    }

    /// Whether adaptive transmission (learning from session and network) is enabled.
    @Published var adaptiveTransmissionEnabled: Bool {
        didSet { persistAdaptiveTransmissionEnabled() }
    }

    /// AX.25 T1 retransmit timeout (seconds), clamped to safe bounds.
    @Published var ax25T1TimeoutSeconds: Double {
        didSet {
            let sanitized = Self.sanitizeAX25T1TimeoutSeconds(ax25T1TimeoutSeconds)
            guard sanitized == ax25T1TimeoutSeconds else {
                // Correct in place rather than deferring: this value feeds the AX.25 T1
                // retransmit timer, so the store must never publish an out-of-range T1
                // even transiently. Assigning here re-enters didSet exactly once — the
                // sanitizer is idempotent, so that pass takes the persist branch and stops.
                ax25T1TimeoutSeconds = sanitized
                return
            }
            persistAX25T1TimeoutSeconds()
        }
    }

    /// TNC capability model — gates which link-layer settings AXTerm can control.
    @Published var tncCapabilities: TNCCapabilities {
        didSet { persistTNCCapabilities() }
    }

    // MARK: - File Transfer Settings

    /// Callsigns that are always allowed to send files without prompting
    @Published var allowedFileTransferCallsigns: [String] {
        didSet {
            persistAllowedFileTransferCallsigns()
        }
    }

    /// Check if a callsign is in the allowed list
    func isCallsignAllowedForFileTransfer(_ callsign: String) -> Bool {
        let normalized = CallsignValidator.normalize(callsign)
        return allowedFileTransferCallsigns.contains { CallsignValidator.normalize($0) == normalized }
    }

    /// Add a callsign to the allowed list
    func allowCallsignForFileTransfer(_ callsign: String) {
        let normalized = CallsignValidator.normalize(callsign)
        guard !normalized.isEmpty, !isCallsignAllowedForFileTransfer(normalized) else { return }
        allowedFileTransferCallsigns.append(normalized)
    }

    /// Remove a callsign from the allowed list
    func removeCallsignFromFileTransferAllowlist(_ callsign: String) {
        let normalized = CallsignValidator.normalize(callsign)
        allowedFileTransferCallsigns.removeAll { CallsignValidator.normalize($0) == normalized }
    }

    /// Callsigns that are always denied from sending files
    @Published var deniedFileTransferCallsigns: [String] {
        didSet {
            persistDeniedFileTransferCallsigns()
        }
    }

    /// Check if a callsign is in the denied list
    func isCallsignDeniedForFileTransfer(_ callsign: String) -> Bool {
        let normalized = CallsignValidator.normalize(callsign)
        return deniedFileTransferCallsigns.contains { CallsignValidator.normalize($0) == normalized }
    }

    /// Add a callsign to the denied list
    func denyCallsignForFileTransfer(_ callsign: String) {
        let normalized = CallsignValidator.normalize(callsign)
        guard !normalized.isEmpty, !isCallsignDeniedForFileTransfer(normalized) else { return }
        deniedFileTransferCallsigns.append(normalized)
        // Also remove from allow list if present
        removeCallsignFromFileTransferAllowlist(callsign)
    }

    /// Remove a callsign from the denied list
    func removeCallsignFromFileTransferDenylist(_ callsign: String) {
        let normalized = CallsignValidator.normalize(callsign)
        deniedFileTransferCallsigns.removeAll { CallsignValidator.normalize($0) == normalized }
    }

    /// Add an entry to the service-endpoint ignore list used by graph/routes validation.
    func addIgnoredServiceEndpoint(_ endpoint: String) {
        let normalized = CallsignValidator.normalize(endpoint)
        guard !normalized.isEmpty else { return }
        guard !ignoredServiceEndpoints.contains(normalized) else { return }
        ignoredServiceEndpoints.append(normalized)
    }

    /// Remove an entry from the service-endpoint ignore list.
    func removeIgnoredServiceEndpoint(_ endpoint: String) {
        let normalized = CallsignValidator.normalize(endpoint)
        ignoredServiceEndpoints.removeAll { CallsignValidator.normalize($0) == normalized }
    }

    /// True when endpoint exists in the user-managed service-endpoint ignore list.
    func isServiceEndpointIgnored(_ endpoint: String) -> Bool {
        let normalized = CallsignValidator.normalize(endpoint)
        return ignoredServiceEndpoints.contains(normalized)
    }

    // MARK: - Analytics Settings

    @Published var analyticsTimeframe: String {
        didSet { persistAnalyticsTimeframe() }
    }

    @Published var analyticsBucket: String {
        didSet { persistAnalyticsBucket() }
    }

    @Published var analyticsIncludeVia: Bool {
        didSet { persistAnalyticsIncludeVia() }
    }

    @Published var analyticsMinEdgeCount: Int {
        didSet {
            let clamped = max(1, min(10, analyticsMinEdgeCount))
            guard clamped == analyticsMinEdgeCount else {
                deferUpdate { [weak self, clamped] in
                    self?.analyticsMinEdgeCount = clamped
                }
                return
            }
            persistAnalyticsMinEdgeCount()
        }
    }

    @Published var analyticsMaxNodes: Int {
        didSet {
            let clamped = max(10, min(500, analyticsMaxNodes))
            guard clamped == analyticsMaxNodes else {
                deferUpdate { [weak self, clamped] in
                    self?.analyticsMaxNodes = clamped
                }
                return
            }
            persistAnalyticsMaxNodes()
        }
    }

    @Published var analyticsHubMetric: String {
        didSet { persistAnalyticsHubMetric() }
    }

    @Published var analyticsStationIdentityMode: String {
        didSet { persistAnalyticsStationIdentityMode() }
    }

    @Published var analyticsAutoUpdateEnabled: Bool {
        didSet { persistAnalyticsAutoUpdateEnabled() }
    }

    @Published var ax25NegotiateV22: Bool {
        didSet {
            persistAX25NegotiateV22()
            SessionCoordinator.shared?.sessionManager.negotiateV22 = ax25NegotiateV22
        }
    }

    // MARK: - NET/ROM Route Settings

    @Published var hideExpiredRoutes: Bool {
        didSet { persistHideExpiredRoutes() }
    }

    @Published var routeRetentionDays: Int {
        didSet {
            let clamped = max(Self.minRouteRetentionDays, min(Self.maxRouteRetentionDays, routeRetentionDays))
            guard clamped == routeRetentionDays else {
                deferUpdate { [weak self, clamped] in
                    self?.routeRetentionDays = clamped
                }
                return
            }
            persistRouteRetentionDays()
        }
    }

    /// Stale policy mode: "adaptive" (per-origin) or "global" (fixed TTL)
    @Published var stalePolicyMode: String {
        didSet { persistStalePolicyMode() }
    }

    @Published var globalStaleTTLHours: Int {
        didSet {
            let clamped = max(Self.minGlobalStaleTTLHours, min(Self.maxGlobalStaleTTLHours, globalStaleTTLHours))
            guard clamped == globalStaleTTLHours else {
                deferUpdate { [weak self, clamped] in
                    self?.globalStaleTTLHours = clamped
                }
                return
            }
            persistGlobalStaleTTLHours()
        }
    }

    /// Number of missed broadcasts before considering adaptive routes stale
    @Published var adaptiveStaleMissedBroadcasts: Int {
        didSet {
            let clamped = max(Self.minAdaptiveStaleMissedBroadcasts, min(Self.maxAdaptiveStaleMissedBroadcasts, adaptiveStaleMissedBroadcasts))
            guard clamped == adaptiveStaleMissedBroadcasts else {
                deferUpdate { [weak self, clamped] in
                    self?.adaptiveStaleMissedBroadcasts = clamped
                }
                return
            }
            persistAdaptiveStaleMissedBroadcasts()
        }
    }

    /// Neighbor activity decay TTL in hours
    @Published var neighborStaleTTLHours: Int {
        didSet {
            let clamped = max(Self.minNeighborStaleTTLHours, min(Self.maxNeighborStaleTTLHours, neighborStaleTTLHours))
            guard clamped == neighborStaleTTLHours else {
                deferUpdate { [weak self, clamped] in
                    self?.neighborStaleTTLHours = clamped
                }
                return
            }
            persistNeighborStaleTTLHours()
        }
    }

    /// Link stat activity decay TTL in hours
    @Published var linkStatStaleTTLHours: Int {
        didSet {
            let clamped = max(Self.minLinkStatStaleTTLHours, min(Self.maxLinkStatStaleTTLHours, linkStatStaleTTLHours))
            guard clamped == linkStatStaleTTLHours else {
                deferUpdate { [weak self, clamped] in
                    self?.linkStatStaleTTLHours = clamped
                }
                return
            }
            persistLinkStatStaleTTLHours()
        }
    }

    /// Terminal session clear timestamp - messages before this are hidden
    @Published var terminalClearedAt: Date? {
        didSet { persistTerminalClearedAt() }
    }

    /// Console view clear timestamp - messages before this are hidden
    @Published var consoleClearedAt: Date? {
        didSet { persistConsoleClearedAt() }
    }

    /// Raw view clear timestamp - chunks before this are hidden
    @Published var rawClearedAt: Date? {
        didSet { persistRawClearedAt() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        Self.registerDefaultsIfNeeded(on: defaults)
        let storedHost = defaults.string(forKey: Self.hostKey) ?? Self.defaultHost
        let storedPort = defaults.object(forKey: Self.portKey) as? Int ?? Self.defaultPort
        let storedRetention = defaults.object(forKey: Self.retentionKey) as? Int ?? Self.defaultRetention
        let storedConsoleRetention = defaults.object(forKey: Self.consoleRetentionKey) as? Int ?? Self.defaultConsoleRetention
        let storedRawRetention = defaults.object(forKey: Self.rawRetentionKey) as? Int ?? Self.defaultRawRetention

        let storedEventRetention = defaults.object(forKey: Self.eventRetentionKey) as? Int ?? Self.defaultEventRetention
        
        let storedDurationRaw = defaults.string(forKey: Self.retentionDurationKey)
        let storedRetentionDuration: HistoryRetentionDuration
        if let raw = storedDurationRaw, let duration = HistoryRetentionDuration(rawValue: raw) {
             storedRetentionDuration = duration
        } else {
            // Only infer if no duration is stored (first run after update)
            // Check if current limits match a preset exactly or reasonably close?
            // For now, strict match to avoid accidental flipping.
            if storedRetention == HistoryRetentionDuration.sevenDays.packetLimit {
                storedRetentionDuration = .sevenDays
            } else {
                // Default to custom so we don't change user's existing limits
                storedRetentionDuration = .custom
            }
        }
        
        let storedPersist = defaults.object(forKey: Self.persistKey) as? Bool ?? true
        let storedConsoleSeparators = defaults.object(forKey: Self.consoleSeparatorsKey) as? Bool ?? Self.defaultConsoleSeparators
        let storedRawSeparators = defaults.object(forKey: Self.rawSeparatorsKey) as? Bool ?? Self.defaultRawSeparators
        // Note: runInMenuBar is now a computed property, not stored
        let storedLaunchAtLogin = defaults.object(forKey: Self.launchAtLoginKey) as? Bool ?? Self.defaultLaunchAtLogin
        let storedAutoConnect = defaults.object(forKey: Self.autoConnectKey) as? Bool ?? Self.defaultAutoConnect
        let storedTransportType = defaults.string(forKey: Self.transportTypeKey) ?? Self.defaultTransportType
        let storedSerialDevicePath = defaults.string(forKey: Self.serialDevicePathKey) ?? Self.defaultSerialDevicePath
        let storedSerialBaudRate = defaults.object(forKey: Self.serialBaudRateKey) as? Int ?? Self.defaultSerialBaudRate
        let storedSerialAutoReconnect = defaults.object(forKey: Self.serialAutoReconnectKey) as? Bool ?? Self.defaultSerialAutoReconnect
        let storedBLEPeripheralUUID = defaults.string(forKey: Self.blePeripheralUUIDKey) ?? Self.defaultBLEPeripheralUUID
        let storedBLEPeripheralName = defaults.string(forKey: Self.blePeripheralNameKey) ?? Self.defaultBLEPeripheralName
        let storedBLEAutoReconnect = defaults.object(forKey: Self.bleAutoReconnectKey) as? Bool ?? Self.defaultBLEAutoReconnect

        let storedMobilinkdEnabled = defaults.object(forKey: Self.mobilinkdEnabledKey) as? Bool ?? Self.defaultMobilinkdEnabled
        let storedMobilinkdModemType = defaults.object(forKey: Self.mobilinkdModemTypeKey) as? Int ?? Self.defaultMobilinkdModemType
        let storedMobilinkdOutputGain = defaults.object(forKey: Self.mobilinkdOutputGainKey) as? Int ?? Self.defaultMobilinkdOutputGain
        let storedMobilinkdInputGain = defaults.object(forKey: Self.mobilinkdInputGainKey) as? Int ?? Self.defaultMobilinkdInputGain

        let storedNotifyOnWatch = defaults.object(forKey: Self.notifyOnWatchKey) as? Bool ?? Self.defaultNotifyOnWatch
        let storedNotifyOnNodeMail = defaults.object(forKey: Self.notifyOnNodeMailKey) as? Bool ?? Self.defaultNotifyOnNodeMail
        let storedNotifyOnInboundConnection = defaults.object(forKey: Self.notifyOnInboundConnectionKey) as? Bool ?? Self.defaultNotifyOnInboundConnection
        let storedNotifyOnMention = defaults.object(forKey: Self.notifyOnMentionKey) as? Bool ?? Self.defaultNotifyOnMention
        let storedNotifyPlaySound = defaults.object(forKey: Self.notifyPlaySoundKey) as? Bool ?? Self.defaultNotifyPlaySound
        let storedNotifyOnlyWhenInactive = defaults.object(forKey: Self.notifyOnlyWhenInactiveKey) as? Bool ?? Self.defaultNotifyOnlyWhenInactive
        let storedMyCallsign = defaults.string(forKey: Self.myCallsignKey) ?? ""
        let storedWatchCallsigns = defaults.stringArray(forKey: Self.watchCallsignsKey) ?? []
        let storedWatchKeywords = defaults.stringArray(forKey: Self.watchKeywordsKey) ?? []
        let storedIgnoredServiceEndpoints = defaults.stringArray(forKey: Self.ignoredServiceEndpointsKey) ?? Self.defaultIgnoredServiceEndpoints
        let storedSentryEnabled = defaults.object(forKey: Self.sentryEnabledKey) as? Bool ?? Self.defaultSentryEnabled
        let storedSentrySendPacketContents = defaults.object(forKey: Self.sentrySendPacketContentsKey) as? Bool ?? Self.defaultSentrySendPacketContents
        let storedSentrySendConnectionDetails = defaults.object(forKey: Self.sentrySendConnectionDetailsKey) as? Bool ?? Self.defaultSentrySendConnectionDetails
        let storedAllowedFileTransferCallsigns = defaults.stringArray(forKey: Self.allowedFileTransferCallsignsKey) ?? []
        let storedDeniedFileTransferCallsigns = defaults.stringArray(forKey: Self.deniedFileTransferCallsignsKey) ?? []

        // Analytics settings
        let storedAnalyticsTimeframe = defaults.string(forKey: Self.analyticsTimeframeKey) ?? Self.defaultAnalyticsTimeframe
        let storedAnalyticsBucket = defaults.string(forKey: Self.analyticsBucketKey) ?? Self.defaultAnalyticsBucket
        let storedAnalyticsIncludeVia = defaults.object(forKey: Self.analyticsIncludeViaKey) as? Bool ?? Self.defaultAnalyticsIncludeVia
        let storedAnalyticsMinEdgeCount = defaults.object(forKey: Self.analyticsMinEdgeCountKey) as? Int ?? Self.defaultAnalyticsMinEdgeCount
        let storedAnalyticsMaxNodes = defaults.object(forKey: Self.analyticsMaxNodesKey) as? Int ?? Self.defaultAnalyticsMaxNodes
        let storedAnalyticsHubMetric = defaults.string(forKey: Self.analyticsHubMetricKey) ?? Self.defaultAnalyticsHubMetric
        let storedAnalyticsStationIdentityMode = defaults.string(forKey: Self.analyticsStationIdentityModeKey) ?? Self.defaultAnalyticsStationIdentityMode
        let storedAnalyticsAutoUpdateEnabled = defaults.object(forKey: Self.analyticsAutoUpdateEnabledKey) as? Bool ?? Self.defaultAnalyticsAutoUpdateEnabled
        let storedAX25NegotiateV22 = defaults.object(forKey: Self.ax25NegotiateV22Key) as? Bool ?? Self.defaultAX25NegotiateV22

        // NET/ROM route settings
        let storedHideExpiredRoutes = defaults.object(forKey: Self.hideExpiredRoutesKey) as? Bool ?? Self.defaultHideExpiredRoutes
        let storedRouteRetentionDays = defaults.object(forKey: Self.routeRetentionDaysKey) as? Int ?? Self.defaultRouteRetentionDays
        let storedStalePolicyMode = defaults.string(forKey: Self.stalePolicyModeKey) ?? Self.defaultStalePolicyMode
        let storedGlobalStaleTTLHours = defaults.object(forKey: Self.globalStaleTTLHoursKey) as? Int ?? Self.defaultGlobalStaleTTLHours
        let storedAdaptiveStaleMissedBroadcasts = defaults.object(forKey: Self.adaptiveStaleMissedBroadcastsKey) as? Int ?? Self.defaultAdaptiveStaleMissedBroadcasts
        let storedNeighborStaleTTLHours = defaults.object(forKey: Self.neighborStaleTTLHoursKey) as? Int ?? Self.defaultNeighborStaleTTLHours
        let storedLinkStatStaleTTLHours = defaults.object(forKey: Self.linkStatStaleTTLHoursKey) as? Int ?? Self.defaultLinkStatStaleTTLHours

        // AXDP / transmission extension settings
        let storedAXDPExtensionsEnabled = defaults.object(forKey: Self.axdpExtensionsEnabledKey) as? Bool ?? Self.defaultAXDPExtensionsEnabled
        let storedNetRomAdvertise = defaults.object(forKey: Self.netRomAdvertiseKey) as? Bool ?? Self.defaultNetRomAdvertise
        let storedNetRomForwarding = defaults.object(forKey: Self.netRomForwardingKey) as? Bool ?? Self.defaultNetRomForwarding
        let storedNetRomNodeAlias = defaults.string(forKey: Self.netRomNodeAliasKey) ?? ""
        let storedNetRomBroadcastMinutes = defaults.object(forKey: Self.netRomBroadcastMinutesKey) as? Int ?? Self.defaultNetRomBroadcastMinutes
        let storedBeaconEnabled = defaults.object(forKey: Self.beaconEnabledKey) as? Bool ?? Self.defaultBeaconEnabled
        autoRouteMaxChainLength = defaults.object(forKey: Self.autoRouteMaxChainLengthKey) as? Int ?? 4
        netRomAcceptInbound = defaults.object(forKey: Self.netRomAcceptInboundKey) as? Bool ?? false
        digipeatEnabled = defaults.object(forKey: Self.digipeatEnabledKey) as? Bool ?? false
        digipeatAlias = defaults.string(forKey: Self.digipeatAliasKey) ?? ""
        terminalFontSize = defaults.object(forKey: Self.terminalFontSizeKey) as? Double ?? 11
        let storedBeaconText = defaults.string(forKey: Self.beaconTextKey) ?? ""
        let storedBeaconMinutes = defaults.object(forKey: Self.beaconMinutesKey) as? Int ?? Self.defaultBeaconMinutes
        let storedBeaconPath = defaults.string(forKey: Self.beaconPathKey) ?? ""
        let pingDefaults = PingPolicy.Settings()
        let storedPingEnabled = defaults.object(forKey: Self.pingEnabledKey) as? Bool ?? Self.defaultPingEnabled
        let storedPingStart = defaults.object(forKey: Self.pingWindowStartKey) as? Int ?? pingDefaults.windowStartHour
        let storedPingEnd = defaults.object(forKey: Self.pingWindowEndKey) as? Int ?? pingDefaults.windowEndHour
        let storedPingSpacing = defaults.object(forKey: Self.pingSpacingKey) as? Int ?? pingDefaults.minSecondsBetweenProbes
        let storedPingCooldown = defaults.object(forKey: Self.pingCooldownKey) as? Int ?? pingDefaults.stationCooldownMinutes
        let storedPingMax = defaults.object(forKey: Self.pingMaxPerHourKey) as? Int ?? pingDefaults.maxProbesPerHour
        let storedPingCalled = defaults.object(forKey: Self.pingProbeCalledKey) as? Bool ?? false
        let storedAXDPAutoNegotiate = defaults.object(forKey: Self.axdpAutoNegotiateKey) as? Bool ?? Self.defaultAXDPAutoNegotiate
        let storedAXDPCompressionEnabled = defaults.object(forKey: Self.axdpCompressionEnabledKey) as? Bool ?? Self.defaultAXDPCompressionEnabled
        let storedAXDPCompressionAlgorithm = (defaults.object(forKey: Self.axdpCompressionAlgorithmKey) as? Int).map { UInt8($0) } ?? Self.defaultAXDPCompressionAlgorithm
        let storedAXDPMaxDecompressedPayload = defaults.object(forKey: Self.axdpMaxDecompressedPayloadKey) as? Int ?? Self.defaultAXDPMaxDecompressedPayload
        let storedAXDPShowDecodeDetails = defaults.object(forKey: Self.axdpShowDecodeDetailsKey) as? Bool ?? Self.defaultAXDPShowDecodeDetails
        let storedAdaptiveTransmissionEnabled = defaults.object(forKey: Self.adaptiveTransmissionEnabledKey) as? Bool ?? Self.defaultAdaptiveTransmissionEnabled
        let storedAX25T1TimeoutSeconds = defaults.object(forKey: Self.ax25T1TimeoutSecondsKey) as? Double ?? Self.defaultAX25T1TimeoutSeconds

        // TNC capabilities (JSON-encoded)
        let storedTNCCapabilities: TNCCapabilities
        if let data = defaults.data(forKey: Self.tncCapabilitiesKey),
           let decoded = try? JSONDecoder().decode(TNCCapabilities.self, from: data) {
            storedTNCCapabilities = decoded
        } else {
            storedTNCCapabilities = TNCCapabilities()
        }

        // Clear timestamps (stored as TimeInterval)
        let storedTerminalClearedAt: Date?
        if let timeInterval = defaults.object(forKey: Self.terminalClearedAtKey) as? TimeInterval {
            storedTerminalClearedAt = Date(timeIntervalSince1970: timeInterval)
        } else {
            storedTerminalClearedAt = nil
        }

        let storedConsoleClearedAt: Date?
        if let timeInterval = defaults.object(forKey: Self.consoleClearedAtKey) as? TimeInterval {
            storedConsoleClearedAt = Date(timeIntervalSince1970: timeInterval)
        } else {
            storedConsoleClearedAt = nil
        }

        let storedRawClearedAt: Date?
        if let timeInterval = defaults.object(forKey: Self.rawClearedAtKey) as? TimeInterval {
            storedRawClearedAt = Date(timeIntervalSince1970: timeInterval)
        } else {
            storedRawClearedAt = nil
        }

        self.host = Self.sanitizeHost(storedHost)
        self.port = Self.sanitizePort(storedPort)
        self.retentionLimit = Self.sanitizeRetention(storedRetention)
        self.consoleRetentionLimit = Self.sanitizeLogRetention(storedConsoleRetention)
        self.rawRetentionLimit = Self.sanitizeLogRetention(storedRawRetention)
        self.eventRetentionLimit = Self.sanitizeLogRetention(storedEventRetention)
        self.retentionDuration = storedRetentionDuration // Initialize duration last to avoid triggering didSet logic prematurely if we were setting other props
        self.persistHistory = storedPersist
        self.showConsoleDaySeparators = storedConsoleSeparators
        self.showRawDaySeparators = storedRawSeparators
        // runInMenuBar is computed, no stored property to set
        self.launchAtLogin = storedLaunchAtLogin
        self.autoConnectOnLaunch = storedAutoConnect
        self.transportType = storedTransportType
        self.serialDevicePath = storedSerialDevicePath
        self.serialBaudRate = Self.commonBaudRates.contains(storedSerialBaudRate) ? storedSerialBaudRate : Self.defaultSerialBaudRate
        self.serialAutoReconnect = storedSerialAutoReconnect
        self.blePeripheralUUID = storedBLEPeripheralUUID
        self.blePeripheralName = storedBLEPeripheralName
        self.bleAutoReconnect = storedBLEAutoReconnect

        self.mobilinkdEnabled = storedMobilinkdEnabled
        self.mobilinkdModemType = storedMobilinkdModemType
        self.mobilinkdOutputGain = storedMobilinkdOutputGain
        self.mobilinkdInputGain = storedMobilinkdInputGain

        self.notifyOnWatchHits = storedNotifyOnWatch
        self.notifyOnNodeMail = storedNotifyOnNodeMail
        self.notifyOnInboundConnection = storedNotifyOnInboundConnection
        self.notifyOnMention = storedNotifyOnMention
        self.notifyPlaySound = storedNotifyPlaySound
        self.notifyOnlyWhenInactive = storedNotifyOnlyWhenInactive
        self.keepAwakePolicy = defaults.string(forKey: Self.keepAwakePolicyKey)
            .flatMap(KeepAwakePolicy.init(rawValue:)) ?? .duringTransfers
        self.myCallsignStorage = CallsignValidator.normalize(storedMyCallsign)
        self.watchCallsigns = storedWatchCallsigns
        self.watchKeywords = storedWatchKeywords
        self.ignoredServiceEndpoints = Self.sanitizeWatchList(storedIgnoredServiceEndpoints, normalize: CallsignValidator.normalize)
        self.sentryEnabled = storedSentryEnabled
        self.sentrySendPacketContents = storedSentrySendPacketContents
        self.sentrySendConnectionDetails = storedSentrySendConnectionDetails
        self.allowedFileTransferCallsigns = storedAllowedFileTransferCallsigns
        self.deniedFileTransferCallsigns = storedDeniedFileTransferCallsigns

        // Analytics settings
        self.analyticsTimeframe = storedAnalyticsTimeframe
        self.analyticsBucket = storedAnalyticsBucket
        self.analyticsIncludeVia = storedAnalyticsIncludeVia
        self.analyticsMinEdgeCount = max(1, min(10, storedAnalyticsMinEdgeCount))
        self.analyticsMaxNodes = max(10, min(500, storedAnalyticsMaxNodes))
        self.analyticsHubMetric = storedAnalyticsHubMetric
        self.analyticsStationIdentityMode = storedAnalyticsStationIdentityMode
        self.analyticsAutoUpdateEnabled = storedAnalyticsAutoUpdateEnabled
        self.ax25NegotiateV22 = storedAX25NegotiateV22

        // NET/ROM route settings
        self.hideExpiredRoutes = storedHideExpiredRoutes
        self.routeRetentionDays = max(Self.minRouteRetentionDays, min(Self.maxRouteRetentionDays, storedRouteRetentionDays))
        self.stalePolicyMode = storedStalePolicyMode
        self.globalStaleTTLHours = max(Self.minGlobalStaleTTLHours, min(Self.maxGlobalStaleTTLHours, storedGlobalStaleTTLHours))
        self.adaptiveStaleMissedBroadcasts = max(Self.minAdaptiveStaleMissedBroadcasts, min(Self.maxAdaptiveStaleMissedBroadcasts, storedAdaptiveStaleMissedBroadcasts))
        self.neighborStaleTTLHours = max(Self.minNeighborStaleTTLHours, min(Self.maxNeighborStaleTTLHours, storedNeighborStaleTTLHours))
        self.linkStatStaleTTLHours = max(Self.minLinkStatStaleTTLHours, min(Self.maxLinkStatStaleTTLHours, storedLinkStatStaleTTLHours))

        // AXDP / transmission extension settings
        self.axdpExtensionsEnabled = storedAXDPExtensionsEnabled
        self.netRomAdvertiseSelf = storedNetRomAdvertise
        self.netRomForwarding = storedNetRomForwarding
        self.netRomNodeAlias = storedNetRomNodeAlias
        self.netRomBroadcastMinutes = storedNetRomBroadcastMinutes
        self.beaconEnabled = storedBeaconEnabled
        self.beaconText = storedBeaconText
        self.beaconMinutes = storedBeaconMinutes
        self.beaconPath = storedBeaconPath
        self.pingEnabled = storedPingEnabled
        self.pingWindowStartHour = storedPingStart
        self.pingWindowEndHour = storedPingEnd
        self.pingMinSecondsBetween = storedPingSpacing
        self.pingStationCooldownMinutes = storedPingCooldown
        self.pingMaxProbesPerHour = storedPingMax
        self.pingProbeStationsOthersCall = storedPingCalled
        self.axdpAutoNegotiateCapabilities = storedAXDPAutoNegotiate
        self.axdpCompressionEnabled = storedAXDPCompressionEnabled
        self.axdpCompressionAlgorithmRaw = storedAXDPCompressionAlgorithm
        self.axdpMaxDecompressedPayload = storedAXDPMaxDecompressedPayload
        self.axdpShowDecodeDetails = storedAXDPShowDecodeDetails
        self.adaptiveTransmissionEnabled = storedAdaptiveTransmissionEnabled
        self.ax25T1TimeoutSeconds = Self.sanitizeAX25T1TimeoutSeconds(storedAX25T1TimeoutSeconds)
        self.tncCapabilities = storedTNCCapabilities

        // Clear timestamps
        self.terminalClearedAt = storedTerminalClearedAt
        self.consoleClearedAt = storedConsoleClearedAt
        self.rawClearedAt = storedRawClearedAt

        CallsignValidator.configureIgnoredServiceEndpoints(self.ignoredServiceEndpoints)

        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            Self.testRetainedStores.append(self)
        }
    }

    var portValue: UInt16 {
        UInt16(port)
    }

    private func deferUpdate(_ update: @MainActor @escaping () -> Void) {
        Task { @MainActor in
            update()
        }
    }

    static func sanitizeHost(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultHost : trimmed
    }

    static func sanitizePort(_ value: Int) -> Int {
        return min(max(value, 1), 65_535)
    }

    static func sanitizeRetention(_ value: Int) -> Int {
        // Allow Int.max for "Forever"
        if value == Int.max { return value }
        return min(max(value, minRetention), maxRetention)
    }

    static func sanitizeLogRetention(_ value: Int) -> Int {
        if value == Int.max { return value }
        return min(max(value, minLogRetention), maxLogRetention)
    }

    static func sanitizeAX25T1TimeoutSeconds(_ value: Double) -> Double {
        // Reject non-finite input (a corrupt defaults plist or a bad binding can yield
        // NaN/±Inf). min/max propagate NaN rather than clamping it, and because
        // NaN != NaN the didSet correction below would never reach a fixed point —
        // it would re-correct forever. Fall back to the default instead.
        guard value.isFinite else { return defaultAX25T1TimeoutSeconds }
        let clamped = min(max(value, minAX25T1TimeoutSeconds), maxAX25T1TimeoutSeconds)
        return (clamped * 10).rounded() / 10
    }

    static func sanitizeWatchList(_ values: [String], normalize: (String) -> String) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = normalize(value)
            guard !trimmed.isEmpty else { return nil }
            guard !seen.contains(trimmed) else { return nil }
            seen.insert(trimmed)
            return trimmed
        }
    }

    private func persistHost() {
        defaults.set(host, forKey: Self.hostKey)
    }

    private func persistPort() {
        defaults.set(port, forKey: Self.portKey)
    }

    private func persistRetention() {
        defaults.set(retentionLimit, forKey: Self.retentionKey)
    }

    private func persistConsoleRetention() {
        defaults.set(consoleRetentionLimit, forKey: Self.consoleRetentionKey)
    }

    private func persistRawRetention() {
        defaults.set(rawRetentionLimit, forKey: Self.rawRetentionKey)
    }

    private func persistEventRetention() {
        defaults.set(eventRetentionLimit, forKey: Self.eventRetentionKey)
    }

    private func persistRetentionDuration() {
        defaults.set(retentionDuration.rawValue, forKey: Self.retentionDurationKey)
    }

    private func persistPersistHistory() {
        defaults.set(persistHistory, forKey: Self.persistKey)
    }

    private func persistConsoleSeparators() {
        defaults.set(showConsoleDaySeparators, forKey: Self.consoleSeparatorsKey)
    }

    private func persistRawSeparators() {
        defaults.set(showRawDaySeparators, forKey: Self.rawSeparatorsKey)
    }

    // persistRunInMenuBar removed - runInMenuBar is now a computed property
    // that writes directly to UserDefaults

    private func persistLaunchAtLogin() {
        defaults.set(launchAtLogin, forKey: Self.launchAtLoginKey)
    }

    private func persistAutoConnect() {
        defaults.set(autoConnectOnLaunch, forKey: Self.autoConnectKey)
    }

    private func persistTransportType() {
        defaults.set(transportType, forKey: Self.transportTypeKey)
    }

    private func persistSerialDevicePath() {
        defaults.set(serialDevicePath, forKey: Self.serialDevicePathKey)
    }

    private func persistSerialBaudRate() {
        defaults.set(serialBaudRate, forKey: Self.serialBaudRateKey)
    }

    private func persistSerialAutoReconnect() {
        defaults.set(serialAutoReconnect, forKey: Self.serialAutoReconnectKey)
    }

    private func persistBLEPeripheralUUID() {
        defaults.set(blePeripheralUUID, forKey: Self.blePeripheralUUIDKey)
    }

    private func persistBLEPeripheralName() {
        defaults.set(blePeripheralName, forKey: Self.blePeripheralNameKey)
    }

    private func persistBLEAutoReconnect() {
        defaults.set(bleAutoReconnect, forKey: Self.bleAutoReconnectKey)
    }

    private func persistMobilinkdEnabled() {
        defaults.set(mobilinkdEnabled, forKey: Self.mobilinkdEnabledKey)
    }

    private func persistMobilinkdModemType() {
        defaults.set(mobilinkdModemType, forKey: Self.mobilinkdModemTypeKey)
    }

    private func persistMobilinkdOutputGain() {
        defaults.set(mobilinkdOutputGain, forKey: Self.mobilinkdOutputGainKey)
    }

    private func persistMobilinkdInputGain() {
        defaults.set(mobilinkdInputGain, forKey: Self.mobilinkdInputGainKey)
    }

    private func persistNotifyOnWatch() {
        defaults.set(notifyOnWatchHits, forKey: Self.notifyOnWatchKey)
    }

    private func persistNotifyOnNodeMail() {
        defaults.set(notifyOnNodeMail, forKey: Self.notifyOnNodeMailKey)
    }

    private func persistNotifyOnInboundConnection() {
        defaults.set(notifyOnInboundConnection, forKey: Self.notifyOnInboundConnectionKey)
    }

    private func persistNotifyOnMention() {
        defaults.set(notifyOnMention, forKey: Self.notifyOnMentionKey)
    }

    private func persistNotifyPlaySound() {
        defaults.set(notifyPlaySound, forKey: Self.notifyPlaySoundKey)
    }

    private func persistNotifyOnlyWhenInactive() {
        defaults.set(notifyOnlyWhenInactive, forKey: Self.notifyOnlyWhenInactiveKey)
    }

    private func persistMyCallsign() {
        defaults.set(myCallsign, forKey: Self.myCallsignKey)
    }

    private func persistWatchCallsigns() {
        defaults.set(watchCallsigns, forKey: Self.watchCallsignsKey)
    }

    private func persistWatchKeywords() {
        defaults.set(watchKeywords, forKey: Self.watchKeywordsKey)
    }

    private func persistIgnoredServiceEndpoints() {
        defaults.set(ignoredServiceEndpoints, forKey: Self.ignoredServiceEndpointsKey)
    }

    private func persistSentryEnabled() {
        defaults.set(sentryEnabled, forKey: Self.sentryEnabledKey)
    }

    private func persistSentrySendPacketContents() {
        defaults.set(sentrySendPacketContents, forKey: Self.sentrySendPacketContentsKey)
    }

    private func persistSentrySendConnectionDetails() {
        defaults.set(sentrySendConnectionDetails, forKey: Self.sentrySendConnectionDetailsKey)
    }

    // MARK: - AXDP / Transmission Extension Persistence

    private func persistAXDPExtensionsEnabled() {
        defaults.set(axdpExtensionsEnabled, forKey: Self.axdpExtensionsEnabledKey)
    }

    private func persistAXDPAutoNegotiateCapabilities() {
        defaults.set(axdpAutoNegotiateCapabilities, forKey: Self.axdpAutoNegotiateKey)
    }

    private func persistAXDPCompressionEnabled() {
        defaults.set(axdpCompressionEnabled, forKey: Self.axdpCompressionEnabledKey)
    }

    private func persistAXDPCompressionAlgorithm() {
        defaults.set(Int(axdpCompressionAlgorithmRaw), forKey: Self.axdpCompressionAlgorithmKey)
    }

    private func persistAXDPMaxDecompressedPayload() {
        defaults.set(axdpMaxDecompressedPayload, forKey: Self.axdpMaxDecompressedPayloadKey)
    }

    private func persistAXDPShowDecodeDetails() {
        defaults.set(axdpShowDecodeDetails, forKey: Self.axdpShowDecodeDetailsKey)
    }

    private func persistAdaptiveTransmissionEnabled() {
        defaults.set(adaptiveTransmissionEnabled, forKey: Self.adaptiveTransmissionEnabledKey)
    }

    private func persistAX25T1TimeoutSeconds() {
        defaults.set(ax25T1TimeoutSeconds, forKey: Self.ax25T1TimeoutSecondsKey)
    }

    private func persistTNCCapabilities() {
        if let data = try? JSONEncoder().encode(tncCapabilities) {
            defaults.set(data, forKey: Self.tncCapabilitiesKey)
        }
    }

    private func persistAllowedFileTransferCallsigns() {
        defaults.set(allowedFileTransferCallsigns, forKey: Self.allowedFileTransferCallsignsKey)
    }

    private func persistDeniedFileTransferCallsigns() {
        defaults.set(deniedFileTransferCallsigns, forKey: Self.deniedFileTransferCallsignsKey)
    }

    // MARK: - Analytics Settings Persistence

    private func persistAnalyticsTimeframe() {
        defaults.set(analyticsTimeframe, forKey: Self.analyticsTimeframeKey)
    }

    private func persistAnalyticsBucket() {
        defaults.set(analyticsBucket, forKey: Self.analyticsBucketKey)
    }

    private func persistAnalyticsIncludeVia() {
        defaults.set(analyticsIncludeVia, forKey: Self.analyticsIncludeViaKey)
    }

    private func persistAnalyticsMinEdgeCount() {
        defaults.set(analyticsMinEdgeCount, forKey: Self.analyticsMinEdgeCountKey)
    }

    private func persistAnalyticsMaxNodes() {
        defaults.set(analyticsMaxNodes, forKey: Self.analyticsMaxNodesKey)
    }

    private func persistAnalyticsHubMetric() {
        defaults.set(analyticsHubMetric, forKey: Self.analyticsHubMetricKey)
    }

    private func persistAnalyticsStationIdentityMode() {
        defaults.set(analyticsStationIdentityMode, forKey: Self.analyticsStationIdentityModeKey)
    }

    private func persistAnalyticsAutoUpdateEnabled() {
        defaults.set(analyticsAutoUpdateEnabled, forKey: Self.analyticsAutoUpdateEnabledKey)
    }

    private func persistAX25NegotiateV22() {
        defaults.set(ax25NegotiateV22, forKey: Self.ax25NegotiateV22Key)
    }

    // MARK: - NET/ROM Route Settings Persistence

    private func persistHideExpiredRoutes() {
        defaults.set(hideExpiredRoutes, forKey: Self.hideExpiredRoutesKey)
    }

    private func persistRouteRetentionDays() {
        defaults.set(routeRetentionDays, forKey: Self.routeRetentionDaysKey)
    }

    private func persistStalePolicyMode() {
        defaults.set(stalePolicyMode, forKey: Self.stalePolicyModeKey)
    }

    private func persistGlobalStaleTTLHours() {
        defaults.set(globalStaleTTLHours, forKey: Self.globalStaleTTLHoursKey)
    }

    private func persistAdaptiveStaleMissedBroadcasts() {
        defaults.set(adaptiveStaleMissedBroadcasts, forKey: Self.adaptiveStaleMissedBroadcastsKey)
    }

    private func persistNeighborStaleTTLHours() {
        defaults.set(neighborStaleTTLHours, forKey: Self.neighborStaleTTLHoursKey)
    }

    private func persistLinkStatStaleTTLHours() {
        defaults.set(linkStatStaleTTLHours, forKey: Self.linkStatStaleTTLHoursKey)
    }

    private func persistTerminalClearedAt() {
        if let date = terminalClearedAt {
            defaults.set(date.timeIntervalSince1970, forKey: Self.terminalClearedAtKey)
        } else {
            defaults.removeObject(forKey: Self.terminalClearedAtKey)
        }
    }

    private func persistConsoleClearedAt() {
        if let date = consoleClearedAt {
            defaults.set(date.timeIntervalSince1970, forKey: Self.consoleClearedAtKey)
        } else {
            defaults.removeObject(forKey: Self.consoleClearedAtKey)
        }
    }

    private func persistRawClearedAt() {
        if let date = rawClearedAt {
            defaults.set(date.timeIntervalSince1970, forKey: Self.rawClearedAtKey)
        } else {
            defaults.removeObject(forKey: Self.rawClearedAtKey)
        }
    }

    private static func registerDefaultsIfNeeded(on defaults: UserDefaults) {
        defaults.register(defaults: [
            Self.hostKey: Self.defaultHost,
            Self.portKey: String(Self.defaultPort),
            Self.retentionKey: Self.defaultRetention,
            Self.consoleRetentionKey: Self.defaultConsoleRetention,
            Self.rawRetentionKey: Self.defaultRawRetention,
            Self.eventRetentionKey: Self.defaultEventRetention,
            Self.persistKey: true,
            Self.consoleSeparatorsKey: Self.defaultConsoleSeparators,
            Self.rawSeparatorsKey: Self.defaultRawSeparators,
            Self.runInMenuBarKey: Self.defaultRunInMenuBar,
            Self.launchAtLoginKey: Self.defaultLaunchAtLogin,
            Self.autoConnectKey: Self.defaultAutoConnect,
            Self.transportTypeKey: Self.defaultTransportType,
            Self.serialDevicePathKey: Self.defaultSerialDevicePath,
            Self.serialBaudRateKey: Self.defaultSerialBaudRate,
            Self.serialAutoReconnectKey: Self.defaultSerialAutoReconnect,
            Self.blePeripheralUUIDKey: Self.defaultBLEPeripheralUUID,
            Self.blePeripheralNameKey: Self.defaultBLEPeripheralName,
            Self.bleAutoReconnectKey: Self.defaultBLEAutoReconnect,
            Self.notifyOnWatchKey: Self.defaultNotifyOnWatch,
            Self.notifyPlaySoundKey: Self.defaultNotifyPlaySound,
            Self.notifyOnlyWhenInactiveKey: Self.defaultNotifyOnlyWhenInactive,
            Self.myCallsignKey: "",
            Self.watchCallsignsKey: [String](),
            Self.watchKeywordsKey: [String](),
            Self.ignoredServiceEndpointsKey: Self.defaultIgnoredServiceEndpoints,
            Self.sentryEnabledKey: Self.defaultSentryEnabled,
            Self.sentrySendPacketContentsKey: Self.defaultSentrySendPacketContents,
            Self.sentrySendConnectionDetailsKey: Self.defaultSentrySendConnectionDetails,
            Self.allowedFileTransferCallsignsKey: [String](),
            Self.deniedFileTransferCallsignsKey: [String](),
            Self.analyticsTimeframeKey: Self.defaultAnalyticsTimeframe,
            Self.analyticsBucketKey: Self.defaultAnalyticsBucket,
            Self.analyticsIncludeViaKey: Self.defaultAnalyticsIncludeVia,
            Self.analyticsMinEdgeCountKey: Self.defaultAnalyticsMinEdgeCount,
            Self.analyticsMaxNodesKey: Self.defaultAnalyticsMaxNodes,
            Self.analyticsHubMetricKey: Self.defaultAnalyticsHubMetric,
            Self.analyticsStationIdentityModeKey: Self.defaultAnalyticsStationIdentityMode,
            Self.analyticsAutoUpdateEnabledKey: Self.defaultAnalyticsAutoUpdateEnabled,
            Self.hideExpiredRoutesKey: Self.defaultHideExpiredRoutes,
            Self.routeRetentionDaysKey: Self.defaultRouteRetentionDays,
            Self.stalePolicyModeKey: Self.defaultStalePolicyMode,
            Self.globalStaleTTLHoursKey: Self.defaultGlobalStaleTTLHours,
            Self.adaptiveStaleMissedBroadcastsKey: Self.defaultAdaptiveStaleMissedBroadcasts,
            Self.neighborStaleTTLHoursKey: Self.defaultNeighborStaleTTLHours,
            Self.linkStatStaleTTLHoursKey: Self.defaultLinkStatStaleTTLHours,
            Self.axdpExtensionsEnabledKey: Self.defaultAXDPExtensionsEnabled,
            Self.netRomAdvertiseKey: Self.defaultNetRomAdvertise,
            Self.netRomForwardingKey: Self.defaultNetRomForwarding,
            Self.beaconEnabledKey: Self.defaultBeaconEnabled,
            Self.beaconMinutesKey: Self.defaultBeaconMinutes,
            Self.netRomBroadcastMinutesKey: Self.defaultNetRomBroadcastMinutes,
            Self.axdpAutoNegotiateKey: Self.defaultAXDPAutoNegotiate,
            Self.axdpCompressionEnabledKey: Self.defaultAXDPCompressionEnabled,
            Self.axdpCompressionAlgorithmKey: Self.defaultAXDPCompressionAlgorithm,
            Self.axdpMaxDecompressedPayloadKey: Self.defaultAXDPMaxDecompressedPayload,
            Self.axdpShowDecodeDetailsKey: Self.defaultAXDPShowDecodeDetails,
            Self.adaptiveTransmissionEnabledKey: Self.defaultAdaptiveTransmissionEnabled,
            Self.ax25T1TimeoutSecondsKey: Self.defaultAX25T1TimeoutSeconds
        ])
    }

}
