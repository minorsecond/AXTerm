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
    private let client: CMSClienting
    private let settings: WinlinkSettings

    init(store: WinlinkStore, client: CMSClienting, settings: WinlinkSettings) {
        self.store = store
        self.client = client
        self.settings = settings
        loadCache()
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
            let fresh = try await client.gatewayProximity(
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
        settings.gatewayCallsign = station.callsign
    }

    var currentGateway: String { settings.gatewayCallsign }

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
