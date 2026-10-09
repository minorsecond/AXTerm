import Combine
import Foundation

/// Fetches bytes for a hazard feed. The app uses URLSession; tests stand in.
protocol HazardFetching: Sendable {
    func data(for request: URLRequest) async throws -> Data
}

/// The last good copy of each feed, on disk, so a relaunch with no
/// connection still has something to show, at its real age
/// (Docs/HazardLayers.md §1).
nonisolated final class HazardDiskCache: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    private struct Stamp: Codable { let fetchedAt: Date }

    private var alertsFile: URL { directory.appendingPathComponent("nws-alerts.json") }
    private var alertsStamp: URL { directory.appendingPathComponent("nws-alerts.stamp.json") }
    private var zonesDirectory: URL { directory.appendingPathComponent("nws-zones", isDirectory: true) }

    func saveAlerts(_ data: Data, fetchedAt: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: alertsFile, options: .atomic)
        try JSONEncoder().encode(Stamp(fetchedAt: fetchedAt)).write(to: alertsStamp, options: .atomic)
    }

    func loadAlerts() -> (data: Data, fetchedAt: Date)? {
        guard let data = try? Data(contentsOf: alertsFile),
              let stamp = try? JSONDecoder().decode(Stamp.self, from: Data(contentsOf: alertsStamp))
        else { return nil }
        return (data, stamp.fetchedAt)
    }

    /// Saved under the code it was asked for, e.g. `COC007`.
    func saveZone(_ id: String, data: Data) throws {
        try FileManager.default.createDirectory(at: zonesDirectory, withIntermediateDirectories: true)
        try data.write(to: zonesDirectory.appendingPathComponent("\(id).json"), options: .atomic)
    }

    func zoneOutlines() -> [String: NWSAlertFeed.Zone] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: zonesDirectory, includingPropertiesForKeys: nil)) ?? []
        var outlines: [String: NWSAlertFeed.Zone] = [:]
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let zone = try? NWSAlertFeed.parseZone(data) {
                outlines[file.deletingPathExtension().lastPathComponent] = zone
            }
        }
        return outlines
    }
}

/// NWS watches, warnings and advisories near the station, kept current
/// while there is a connection and kept, marked stale, when there is not.
@MainActor
final class NWSAlertLayer: ObservableObject {
    /// Without a good fetch for this long, the alerts shown are stale.
    static let staleAfter: TimeInterval = 10 * 60

    @Published private(set) var features: [HazardFeature] = []
    /// When the alerts shown were fetched.
    @Published private(set) var lastFetched: Date?
    /// Why the last refresh failed, or nil when it worked.
    @Published private(set) var problem: String?

    private let fetcher: HazardFetching
    private let cache: HazardDiskCache
    /// Every good fetch is recorded (Docs/HazardLayers.md §8).
    private let history: SQLiteHazardHistoryStore?
    private let now: () -> Date
    private var outlines: [String: NWSAlertFeed.Zone]?

    init(fetcher: HazardFetching, cache: HazardDiskCache, history: SQLiteHazardHistoryStore? = nil,
         now: @escaping () -> Date = Date.init) {
        self.fetcher = fetcher
        self.cache = cache
        self.history = history
        self.now = now
    }

    var isStale: Bool {
        guard let lastFetched else { return false }
        return now().timeIntervalSince(lastFetched) > Self.staleAfter
    }

    /// The last good copy from disk, at the time it was fetched.
    func loadCached() {
        guard let saved = cache.loadAlerts(),
              let parsed = try? NWSAlertFeed.parse(saved.data, fetchedAt: saved.fetchedAt) else { return }
        features = NWSAlertFeed.resolvingZones(parsed, outlines: knownOutlines())
        lastFetched = saved.fetchedAt
    }

    func refresh(near point: GreatCircle.Point) async {
        let parsed: [HazardFeature]
        let fetchedAt = now()
        do {
            let data = try await fetcher.data(for: NWSAlertFeed.alertsRequest(near: point))
            parsed = try NWSAlertFeed.parse(data, fetchedAt: fetchedAt)
            try? cache.saveAlerts(data, fetchedAt: fetchedAt)
        } catch {
            problem = "Could not reach the National Weather Service (\(error.localizedDescription)). "
                + (lastFetched == nil ? "No alerts have been fetched yet." : "Showing the alerts fetched earlier.")
            return
        }
        lastFetched = fetchedAt
        problem = nil
        var known = knownOutlines()
        for url in NWSAlertFeed.zonesToFetch(for: parsed, cached: Set(known.keys)) {
            let id = url.lastPathComponent
            guard let data = try? await fetcher.data(for: NWSAlertFeed.zoneRequest(url)),
                  let zone = try? NWSAlertFeed.parseZone(data) else { continue }
            known[id] = zone
            try? cache.saveZone(id, data: data)
        }
        outlines = known
        features = NWSAlertFeed.resolvingZones(parsed, outlines: known)
        // History is a record, not the display: a write that fails costs
        // the record, never the alerts on screen.
        try? history?.record(features)
    }

    private func knownOutlines() -> [String: NWSAlertFeed.Zone] {
        if let outlines { return outlines }
        let loaded = cache.zoneOutlines()
        outlines = loaded
        return loaded
    }
}

enum HazardFetchError: Error, Equatable, LocalizedError {
    /// The server answered with an HTTP error, e.g. 503 when the NWS is
    /// overloaded. Its body is a problem document, not alerts.
    case status(Int)
    /// Refused before any request: a test run reaches loopback only.
    case notAllowed(String)

    var errorDescription: String? {
        switch self {
        case .status(let code): return "the server answered HTTP \(code)"
        case .notAllowed(let host): return "\(host) is not reachable from a test run"
        }
    }
}

/// Hazard feeds over URLSession.
struct URLSessionHazardFetcher: HazardFetching {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> Data {
        let host = request.url?.host ?? ""
        guard AppEnvironment.mayConnect(to: host) else { throw HazardFetchError.notAllowed(host) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HazardFetchError.status(http.statusCode)
        }
        return data
    }
}
