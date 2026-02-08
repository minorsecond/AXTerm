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
    static let persistKey = "persistHistory"
    static let consoleSeparatorsKey = "consoleDaySeparators"
    static let rawSeparatorsKey = "rawDaySeparators"
    static let runInMenuBarKey = "runInMenuBar"
    static let launchAtLoginKey = "launchAtLogin"
    static let autoConnectKey = "autoConnectOnLaunch"
    static let notifyOnWatchKey = "notifyOnWatchHits"
    static let notifyPlaySoundKey = "notifyPlaySound"
    static let notifyOnlyWhenInactiveKey = "notifyOnlyWhenInactive"
    static let myCallsignKey = "myCallsign"
    static let watchCallsignsKey = "watchCallsigns"
    static let watchKeywordsKey = "watchKeywords"
    static let sentryEnabledKey = "sentryEnabled"
    static let sentrySendPacketContentsKey = "sentrySendPacketContents"
    static let sentrySendConnectionDetailsKey = "sentrySendConnectionDetails"

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

    // AXDP / transmission extension settings keys
    static let axdpExtensionsEnabledKey = "axdpExtensionsEnabled"
    static let axdpAutoNegotiateKey = "axdpAutoNegotiateCapabilities"
    static let axdpCompressionEnabledKey = "axdpCompressionEnabled"
    static let axdpCompressionAlgorithmKey = "axdpCompressionAlgorithm"
    static let axdpMaxDecompressedPayloadKey = "axdpMaxDecompressedPayload"
    static let axdpShowDecodeDetailsKey = "axdpShowAXDPDecodeDetails"
    static let adaptiveTransmissionEnabledKey = "adaptiveTransmissionEnabled"

    // NET/ROM route settings keys
    static let hideExpiredRoutesKey = "hideExpiredRoutes"
    static let routeRetentionDaysKey = "routeRetentionDays"
    static let stalePolicyModeKey = "stalePolicyMode"
    static let globalStaleTTLHoursKey = "globalStaleTTLHours"
    static let adaptiveStaleMissedBroadcastsKey = "adaptiveStaleMissedBroadcasts"
    static let neighborStaleTTLHoursKey = "neighborStaleTTLHours"
    static let linkStatStaleTTLHoursKey = "linkStatStaleTTLHours"

    static let defaultHost = "localhost"
    static let defaultPort = 8001
    static let defaultRetention = 50_000
    static let minRetention = 1_000
    static let maxRetention = 500_000
    static let defaultConsoleRetention = 10_000
    static let defaultRawRetention = 10_000
    static let defaultEventRetention = 10_000
    static let minLogRetention = 1_000
    static let maxLogRetention = 200_000
    static let defaultConsoleSeparators = true
    static let defaultRawSeparators = false
    static let defaultRunInMenuBar = false
    static let defaultLaunchAtLogin = false
    static let defaultAutoConnect = false
    static let defaultNotifyOnWatch = true
    static let defaultNotifyPlaySound = true
    static let defaultNotifyOnlyWhenInactive = true
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

    // AXDP defaults (match TxAdaptiveSettings defaults)
    static let defaultAXDPExtensionsEnabled = true
    static let defaultAXDPAutoNegotiate = false
    static let defaultAXDPCompressionEnabled = true
    static let defaultAXDPCompressionAlgorithm: UInt8 = 1  // AXDPCompression.Algorithm.lz4
    static let defaultAXDPMaxDecompressedPayload = 4096
    static let defaultAXDPShowDecodeDetails = false
    static let defaultAdaptiveTransmissionEnabled = true

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

    @Published var port: String {
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

    @Published var notifyOnWatchHits: Bool {
        didSet { persistNotifyOnWatch() }
    }

    @Published var notifyPlaySound: Bool {
        didSet { persistNotifyPlaySound() }
    }

    @Published var notifyOnlyWhenInactive: Bool {
        didSet { persistNotifyOnlyWhenInactive() }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.registerDefaultsIfNeeded(on: defaults)
        let storedHost = defaults.string(forKey: Self.hostKey) ?? Self.defaultHost
        let storedPort = defaults.string(forKey: Self.portKey) ?? String(Self.defaultPort)
        let storedRetention = defaults.object(forKey: Self.retentionKey) as? Int ?? Self.defaultRetention
        let storedConsoleRetention = defaults.object(forKey: Self.consoleRetentionKey) as? Int ?? Self.defaultConsoleRetention
        let storedRawRetention = defaults.object(forKey: Self.rawRetentionKey) as? Int ?? Self.defaultRawRetention
        let storedEventRetention = defaults.object(forKey: Self.eventRetentionKey) as? Int ?? Self.defaultEventRetention
        let storedPersist = defaults.object(forKey: Self.persistKey) as? Bool ?? true
        let storedConsoleSeparators = defaults.object(forKey: Self.consoleSeparatorsKey) as? Bool ?? Self.defaultConsoleSeparators
        let storedRawSeparators = defaults.object(forKey: Self.rawSeparatorsKey) as? Bool ?? Self.defaultRawSeparators
        // Note: runInMenuBar is now a computed property, not stored
        let storedLaunchAtLogin = defaults.object(forKey: Self.launchAtLoginKey) as? Bool ?? Self.defaultLaunchAtLogin
        let storedAutoConnect = defaults.object(forKey: Self.autoConnectKey) as? Bool ?? Self.defaultAutoConnect
        let storedNotifyOnWatch = defaults.object(forKey: Self.notifyOnWatchKey) as? Bool ?? Self.defaultNotifyOnWatch
        let storedNotifyPlaySound = defaults.object(forKey: Self.notifyPlaySoundKey) as? Bool ?? Self.defaultNotifyPlaySound
        let storedNotifyOnlyWhenInactive = defaults.object(forKey: Self.notifyOnlyWhenInactiveKey) as? Bool ?? Self.defaultNotifyOnlyWhenInactive
        let storedMyCallsign = defaults.string(forKey: Self.myCallsignKey) ?? ""
        let storedWatchCallsigns = defaults.stringArray(forKey: Self.watchCallsignsKey) ?? []
        let storedWatchKeywords = defaults.stringArray(forKey: Self.watchKeywordsKey) ?? []
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
        let storedAXDPAutoNegotiate = defaults.object(forKey: Self.axdpAutoNegotiateKey) as? Bool ?? Self.defaultAXDPAutoNegotiate
        let storedAXDPCompressionEnabled = defaults.object(forKey: Self.axdpCompressionEnabledKey) as? Bool ?? Self.defaultAXDPCompressionEnabled
        let storedAXDPCompressionAlgorithm = (defaults.object(forKey: Self.axdpCompressionAlgorithmKey) as? Int).map { UInt8($0) } ?? Self.defaultAXDPCompressionAlgorithm
        let storedAXDPMaxDecompressedPayload = defaults.object(forKey: Self.axdpMaxDecompressedPayloadKey) as? Int ?? Self.defaultAXDPMaxDecompressedPayload
        let storedAXDPShowDecodeDetails = defaults.object(forKey: Self.axdpShowDecodeDetailsKey) as? Bool ?? Self.defaultAXDPShowDecodeDetails
        let storedAdaptiveTransmissionEnabled = defaults.object(forKey: Self.adaptiveTransmissionEnabledKey) as? Bool ?? Self.defaultAdaptiveTransmissionEnabled

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
        self.persistHistory = storedPersist
        self.showConsoleDaySeparators = storedConsoleSeparators
        self.showRawDaySeparators = storedRawSeparators
        // runInMenuBar is computed, no stored property to set
        self.launchAtLogin = storedLaunchAtLogin
        self.autoConnectOnLaunch = storedAutoConnect
        self.notifyOnWatchHits = storedNotifyOnWatch
        self.notifyPlaySound = storedNotifyPlaySound
        self.notifyOnlyWhenInactive = storedNotifyOnlyWhenInactive
        self.myCallsignStorage = CallsignValidator.normalize(storedMyCallsign)
        self.watchCallsigns = storedWatchCallsigns
        self.watchKeywords = storedWatchKeywords
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
        self.axdpAutoNegotiateCapabilities = storedAXDPAutoNegotiate
        self.axdpCompressionEnabled = storedAXDPCompressionEnabled
        self.axdpCompressionAlgorithmRaw = storedAXDPCompressionAlgorithm
        self.axdpMaxDecompressedPayload = storedAXDPMaxDecompressedPayload
        self.axdpShowDecodeDetails = storedAXDPShowDecodeDetails
        self.adaptiveTransmissionEnabled = storedAdaptiveTransmissionEnabled

        // Clear timestamps
        self.terminalClearedAt = storedTerminalClearedAt
        self.consoleClearedAt = storedConsoleClearedAt
        self.rawClearedAt = storedRawClearedAt

        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            Self.testRetainedStores.append(self)
        }
    }

    var portValue: UInt16 {
        UInt16(Self.sanitizePort(port)) ?? UInt16(Self.defaultPort)
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

    static func sanitizePort(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let portValue = Int(trimmed) else { return String(defaultPort) }
        let clamped = min(max(portValue, 1), 65_535)
        return String(clamped)
    }

    static func sanitizeRetention(_ value: Int) -> Int {
        min(max(value, minRetention), maxRetention)
    }

    static func sanitizeLogRetention(_ value: Int) -> Int {
        min(max(value, minLogRetention), maxLogRetention)
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

    private func persistNotifyOnWatch() {
        defaults.set(notifyOnWatchHits, forKey: Self.notifyOnWatchKey)
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
            Self.notifyOnWatchKey: Self.defaultNotifyOnWatch,
            Self.notifyPlaySoundKey: Self.defaultNotifyPlaySound,
            Self.notifyOnlyWhenInactiveKey: Self.defaultNotifyOnlyWhenInactive,
            Self.myCallsignKey: "",
            Self.watchCallsignsKey: [String](),
            Self.watchKeywordsKey: [String](),
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
            Self.hideExpiredRoutesKey: Self.defaultHideExpiredRoutes,
            Self.routeRetentionDaysKey: Self.defaultRouteRetentionDays,
            Self.stalePolicyModeKey: Self.defaultStalePolicyMode,
            Self.globalStaleTTLHoursKey: Self.defaultGlobalStaleTTLHours,
            Self.adaptiveStaleMissedBroadcastsKey: Self.defaultAdaptiveStaleMissedBroadcasts,
            Self.neighborStaleTTLHoursKey: Self.defaultNeighborStaleTTLHours,
            Self.linkStatStaleTTLHoursKey: Self.defaultLinkStatStaleTTLHours,
            Self.axdpExtensionsEnabledKey: Self.defaultAXDPExtensionsEnabled,
            Self.axdpAutoNegotiateKey: Self.defaultAXDPAutoNegotiate,
            Self.axdpCompressionEnabledKey: Self.defaultAXDPCompressionEnabled,
            Self.axdpCompressionAlgorithmKey: Self.defaultAXDPCompressionAlgorithm,
            Self.axdpMaxDecompressedPayloadKey: Self.defaultAXDPMaxDecompressedPayload,
            Self.axdpShowDecodeDetailsKey: Self.defaultAXDPShowDecodeDetails,
            Self.adaptiveTransmissionEnabledKey: Self.defaultAdaptiveTransmissionEnabled
        ])
    }

}
