//
//  AppSettingsStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation
import Combine

@MainActor
final class AppSettingsStore: ObservableObject {
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

    // Analytics settings keys
    static let analyticsTimeframeKey = "analyticsTimeframe"
    static let analyticsBucketKey = "analyticsBucket"
    static let analyticsIncludeViaKey = "analyticsIncludeVia"
    static let analyticsMinEdgeCountKey = "analyticsMinEdgeCount"
    static let analyticsMaxNodesKey = "analyticsMaxNodes"
    static let analyticsHubMetricKey = "analyticsHubMetric"
    static let analyticsStationIdentityModeKey = "analyticsStationIdentityMode"

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

    @Published var myCallsign: String {
        didSet {
            let sanitized = CallsignValidator.normalize(myCallsign)
            guard sanitized == myCallsign else {
                deferUpdate { [weak self, sanitized] in
                    self?.myCallsign = sanitized
                }
                return
            }
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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

        // Analytics settings
        let storedAnalyticsTimeframe = defaults.string(forKey: Self.analyticsTimeframeKey) ?? Self.defaultAnalyticsTimeframe
        let storedAnalyticsBucket = defaults.string(forKey: Self.analyticsBucketKey) ?? Self.defaultAnalyticsBucket
        let storedAnalyticsIncludeVia = defaults.object(forKey: Self.analyticsIncludeViaKey) as? Bool ?? Self.defaultAnalyticsIncludeVia
        let storedAnalyticsMinEdgeCount = defaults.object(forKey: Self.analyticsMinEdgeCountKey) as? Int ?? Self.defaultAnalyticsMinEdgeCount
        let storedAnalyticsMaxNodes = defaults.object(forKey: Self.analyticsMaxNodesKey) as? Int ?? Self.defaultAnalyticsMaxNodes
        let storedAnalyticsHubMetric = defaults.string(forKey: Self.analyticsHubMetricKey) ?? Self.defaultAnalyticsHubMetric
        let storedAnalyticsStationIdentityMode = defaults.string(forKey: Self.analyticsStationIdentityModeKey) ?? Self.defaultAnalyticsStationIdentityMode

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
        self.myCallsign = CallsignValidator.normalize(storedMyCallsign)
        self.watchCallsigns = storedWatchCallsigns
        self.watchKeywords = storedWatchKeywords
        self.sentryEnabled = storedSentryEnabled
        self.sentrySendPacketContents = storedSentrySendPacketContents
        self.sentrySendConnectionDetails = storedSentrySendConnectionDetails

        // Analytics settings
        self.analyticsTimeframe = storedAnalyticsTimeframe
        self.analyticsBucket = storedAnalyticsBucket
        self.analyticsIncludeVia = storedAnalyticsIncludeVia
        self.analyticsMinEdgeCount = max(1, min(10, storedAnalyticsMinEdgeCount))
        self.analyticsMaxNodes = max(10, min(500, storedAnalyticsMaxNodes))
        self.analyticsHubMetric = storedAnalyticsHubMetric
        self.analyticsStationIdentityMode = storedAnalyticsStationIdentityMode
    }

    var portValue: UInt16 {
        UInt16(Self.sanitizePort(port)) ?? UInt16(Self.defaultPort)
    }

    private func deferUpdate(_ update: @MainActor @escaping () -> Void) {
        // `Task.yield()` can still resume within the same SwiftUI update transaction.
        // `DispatchQueue.main.async` reliably defers to the next run loop turn.
        DispatchQueue.main.async { [update] in
            Task { @MainActor in
                update()
            }
        }
    }

    nonisolated static func sanitizeHost(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultHost : trimmed
    }

    nonisolated static func sanitizePort(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let portValue = Int(trimmed) else { return String(defaultPort) }
        let clamped = min(max(portValue, 1), 65_535)
        return String(clamped)
    }

    nonisolated static func sanitizeRetention(_ value: Int) -> Int {
        min(max(value, minRetention), maxRetention)
    }

    nonisolated static func sanitizeLogRetention(_ value: Int) -> Int {
        min(max(value, minLogRetention), maxLogRetention)
    }

    nonisolated static func sanitizeWatchList(_ values: [String], normalize: (String) -> String) -> [String] {
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
}
