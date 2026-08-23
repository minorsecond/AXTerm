import Foundation
import Combine

/// Nearby-RMS-stations list: cache-first, refreshed from the CMS API.
@MainActor
final class RMSStationsViewModel: ObservableObject {

    @Published private(set) var stations: [WinlinkRMSStationRecord] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorText: String?
    @Published private(set) var fetchedAt: Date?

    private let store: WinlinkStore
    /// Built per refresh so a key entered in Settings applies immediately.
    private let makeClient: () -> CMSClienting
    private let settings: WinlinkSettings
    private var settingsSubscription: AnyCancellable?

    init(store: WinlinkStore, makeClient: @escaping () -> CMSClienting, settings: WinlinkSettings) {
        self.store = store
        self.makeClient = makeClient
        self.settings = settings
        loadCache()
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
            try store.replaceStationCache(fresh)
            loadCache()
        } catch {
            errorText = Self.describe(error)
        }
    }

    func setAsGateway(_ station: WinlinkRMSStationRecord) {
        settings.addToLadder(callsign: station.callsign)
        settings.promoteToTop(callsign: station.callsign)
    }

    func addToLadder(_ station: WinlinkRMSStationRecord) {
        settings.addToLadder(callsign: station.callsign)
    }

    func removeFromLadder(_ station: WinlinkRMSStationRecord) {
        settings.removeFromLadder(callsign: station.callsign)
    }

    func promoteToTop(_ station: WinlinkRMSStationRecord) {
        settings.promoteToTop(callsign: station.callsign)
    }

    func ladderRank(of station: WinlinkRMSStationRecord) -> Int? {
        settings.ladderRank(of: station.callsign)
    }

    var ladderSummary: [String] { settings.gatewayLadder.map(\.callsign) }

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
