import Foundation
import Combine

/// Nearby-RMS-stations list: cache-first, refreshed from the CMS API.
@MainActor
final class RMSStationsViewModel: ObservableObject {

    @Published private(set) var stations: [WinlinkRMSStationRecord] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorText: String?
    @Published private(set) var fetchedAt: Date?

    /// Empirical per-link quality from our own session log, keyed by
    /// `WinlinkLinkQuality.linkKey` (callsign@frequency).
    @Published private(set) var linkQuality: [String: WinlinkLinkQuality] = [:]

    private let store: WinlinkStore
    /// Built per refresh so a key entered in Settings applies immediately.
    private let makeClient: () -> CMSClienting
    private let settings: WinlinkSettings
    private var settingsSubscription: AnyCancellable?
    /// Where the operator is, for judging whether a stored measurement
    /// still describes the link from here.
    private let observer: () -> StationLocation?

    init(
        store: WinlinkStore,
        makeClient: @escaping () -> CMSClienting,
        settings: WinlinkSettings,
        observer: @escaping () -> StationLocation? = { nil }
    ) {
        self.store = store
        self.makeClient = makeClient
        self.settings = settings
        self.observer = observer
        loadCache()
        reloadLinkQuality()
        // Ladder edits (from Settings or other rows) must repaint the table.
        settingsSubscription = settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// What blocks a refresh right now, if anything (drives inline banners).
    var refreshBlocker: String? {
        if settings.gridSquare.isEmpty {
            return "Set your grid square in Settings → Winlink to find nearby gateways."
        }
        if !Maidenhead.isValid(settings.gridSquare) {
            return "\"\(settings.gridSquare)\" is not a valid Maidenhead grid square."
        }
        return nil
    }

    func loadCache() {
        do {
            stations = try store.stations()
            fetchedAt = stations.map(\.fetchedAt).max()
        } catch {
            errorText = String(describing: error)
        }
    }

    /// Recomputes the Link column from the session log. Cheap enough to
    /// run after every exchange — the log is one row per session.
    func reloadLinkQuality() {
        let logs = (try? store.sessionLogs(limit: 2000)) ?? []
        linkQuality = WinlinkLinkQuality.summarize(logs: logs, observer: observer())
    }

    /// Quality for one table row, or nil when we have never called it.
    func quality(for station: WinlinkRMSStationRecord) -> WinlinkLinkQuality? {
        let exact = WinlinkLinkQuality.linkKey(
            callsign: station.callsign, frequencyHz: station.frequencyHz)
        if let match = linkQuality[exact] { return match }
        // Sessions logged before migration v8 carry no frequency. They
        // still describe *a* link to this callsign, so they are offered
        // to every row for that callsign — the tooltip's placement text
        // is what stops them being read as more specific than they are.
        return linkQuality[WinlinkLinkQuality.linkKey(
            callsign: station.callsign, frequencyHz: nil)]
    }

    func refresh() async {
        guard refreshBlocker == nil else {
            errorText = refreshBlocker
            return
        }
        guard !isRefreshing else { return }

        isRefreshing = true
        errorText = nil
        defer { isRefreshing = false }

        do {
            let fresh = try await makeClient().gatewayProximity(
                gridSquare: settings.gridSquare,
                maxDistanceMiles: settings.maxDistanceMiles,
                historyHours: settings.historyHours)
            try store.replaceStationCache(fresh, scope: .local)
            loadCache()
        } catch {
            errorText = Self.describe(error)
        }
    }

    /// Downloads gateways for a trip and keeps them apart from the local set.
    ///
    /// One network call either way: `gateway/status.json` has no geographic
    /// filter, so the whole world already arrives on every refresh and the
    /// radius is applied here. This simply stops throwing the rest away.
    ///
    /// `fields` are two-character Maidenhead fields (`DM`, `DN`). Empty keeps
    /// everything, which is a real choice for someone who does not yet know
    /// where they are going.
    @discardableResult
    func downloadForTrip(gridFields fields: Set<String>) async -> Int {
        guard refreshBlocker == nil else {
            errorText = refreshBlocker
            return 0
        }
        guard !isRefreshing else { return 0 }
        isRefreshing = true
        errorText = nil
        defer { isRefreshing = false }

        do {
            // maxDistanceMiles 0 means "do not filter by distance" — the
            // distances are still computed, and stay useful for sorting once
            // the operator arrives.
            let all = try await makeClient().gatewayProximity(
                gridSquare: settings.gridSquare,
                maxDistanceMiles: 0,
                historyHours: settings.historyHours)
            let wanted = Set(fields.map { $0.uppercased() })
            let selected = wanted.isEmpty
                ? all
                : all.filter { wanted.contains($0.gridField) }
            try store.replaceStationCache(selected, scope: .global)
            loadCache()
            return selected.count
        } catch {
            errorText = Self.describe(error)
            return 0
        }
    }

    /// Fields present in the world-wide list, so the operator picks from what
    /// exists rather than typing a grid that has no gateways in it.
    func availableGridFields() async -> [(field: String, count: Int)] {
        guard refreshBlocker == nil else { return [] }
        guard let all = try? await makeClient().gatewayProximity(
            gridSquare: settings.gridSquare,
            maxDistanceMiles: 0,
            historyHours: settings.historyHours) else { return [] }
        return Dictionary(grouping: all, by: \.gridField)
            .map { (field: $0.key, count: $0.value.count) }
            .sorted { ($1.count, $0.field) < ($0.count, $1.field) }
    }

    func clearDownloaded() {
        try? store.clearDownloadedStations()
        loadCache()
    }

    var downloadedFields: [(field: String, count: Int)] {
        (try? store.downloadedGridFields()) ?? []
    }

    /// True when this exact gateway is already a rung.
    func isInLadder(_ station: WinlinkRMSStationRecord) -> Bool {
        entryID(for: station) != nil
    }

    /// How far away the ladder's rungs are, so a rung added for a trip is
    /// visible as such once the operator is home again.
    ///
    /// A downloaded gateway is a legitimate rung — that is the point of
    /// downloading it — but a ladder quietly pointing 400 miles away is a
    /// wasted transmission cycle, and the operator should be able to see it
    /// without cross-referencing two screens.
    func ladderDistanceMiles(callsign: String, frequencyHz: Int?) -> Double? {
        stations.first {
            $0.callsign.caseInsensitiveCompare(callsign) == .orderedSame
                && (frequencyHz == nil || $0.frequencyHz == frequencyHz)
        }?.distanceMiles
    }

    private func entryID(for station: WinlinkRMSStationRecord) -> String? {
        settings.gatewayLadder.first {
            $0.matches(callsign: station.callsign, frequencyHz: station.frequencyHz)
        }?.id
    }

    func addToLadder(_ station: WinlinkRMSStationRecord) {
        settings.addToLadder(callsign: station.callsign, frequencyHz: station.frequencyHz)
    }

    func removeFromLadder(_ station: WinlinkRMSStationRecord) {
        guard let id = entryID(for: station) else { return }
        settings.removeFromLadder(entryID: id)
    }

    func promoteToTop(_ station: WinlinkRMSStationRecord) {
        guard let id = entryID(for: station) else { return }
        settings.promoteToTop(entryID: id)
    }

    func ladderRank(of station: WinlinkRMSStationRecord) -> Int? {
        settings.ladderRank(callsign: station.callsign, frequencyHz: station.frequencyHz)
    }

    var ladderSummary: [String] {
        settings.gatewayLadder.map { entry in
            if let hz = entry.frequencyHz {
                return "\(entry.callsign) \(String(format: "%.3f", Double(hz) / 1_000_000))"
            }
            return entry.callsign
        }
    }

    var currentGateway: String { settings.gatewayLadder.first?.callsign ?? "" }

    static func describe(_ error: Error) -> String {
        switch error {
        case WinlinkCMSError.missingAccessKey:
            return "No CMS access key configured — set one in Settings → Winlink."
        case WinlinkCMSError.invalidGridSquare(let grid):
            return "\"\(grid)\" is not a valid grid square."
        case WinlinkCMSError.httpError(let status):
            return "The Winlink CMS returned HTTP \(status)."
        case WinlinkCMSError.serviceError(let message) where message.lowercased().contains("access key"):
            return "The CMS rejected the access key for this operation. The built-in community key covers the station list; the catalog needs your own key (Settings → Winlink) — or request the catalog over the air instead."
        case WinlinkCMSError.serviceError(let message):
            return "Winlink CMS error: \(message)"
        case WinlinkCMSError.malformedResponse:
            return "The Winlink CMS response could not be parsed."
        default:
            return "Station refresh failed: \(error.localizedDescription)"
        }
    }
}
