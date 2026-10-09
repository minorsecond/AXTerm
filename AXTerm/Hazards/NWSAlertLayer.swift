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

    /// Asked to slow down (HTTP 429 or 503): nothing is fetched before this.
    @Published private(set) var pausedUntil: Date?
    /// Zone outlines still to fetch, a few each refresh (`maxZonesPerRefresh`).
    @Published private(set) var zonesStillLoading = 0
    /// Alerts a radius cannot place yet (`NWSAlertScope.unplaced`).
    @Published private(set) var unplacedCount = 0
    /// The NWS refused the request (HTTP 400 range): the area asked for is
    /// the problem, not the connection.
    @Published private(set) var requestRejected = false

    /// At most this many new zone outlines per refresh, `zonePause` apart. A
    /// statewide storm can name a hundred zones, and asking for all of them
    /// at once is how a client gets throttled.
    private let maxZonesPerRefresh: Int
    private let zonePause: TimeInterval
    private let sleep: (TimeInterval) async -> Void
    /// Slow-downs in a row; each doubles the pause, up to `maxPause`.
    private var consecutiveThrottles = 0
    static let firstPause: TimeInterval = 120
    static let maxPause: TimeInterval = 30 * 60

    init(fetcher: HazardFetching, cache: HazardDiskCache, history: SQLiteHazardHistoryStore? = nil,
         now: @escaping () -> Date = Date.init,
         maxZonesPerRefresh: Int = 25, zonePause: TimeInterval = 0.2,
         sleep: @escaping (TimeInterval) async -> Void = {
             try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
         }) {
        self.maxZonesPerRefresh = maxZonesPerRefresh
        self.zonePause = zonePause
        self.sleep = sleep
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

    /// Alerts at the station's position.
    func refresh(near point: GreatCircle.Point) async {
        await refresh(.here, at: point)
    }

    /// Alerts for a scope (`NWSAlertScope`): at the station, within a radius
    /// of it, for chosen states, or for chosen zones.
    func refresh(_ scope: NWSAlertScope, at point: GreatCircle.Point?) async {
        // Paused at the server's request: ask for nothing until it is over.
        if let pausedUntil, now() < pausedUntil { return }
        guard let request = NWSAlertFeed.alertsRequest(scope, at: point) else {
            problem = "No position for this station, so no alerts can be fetched for where it is."
            return
        }
        let parsed: [HazardFeature]
        let fetchedAt = now()
        do {
            let data = try await fetcher.data(for: request)
            parsed = try NWSAlertFeed.parse(data, fetchedAt: fetchedAt)
            try? cache.saveAlerts(data, fetchedAt: fetchedAt)
        } catch HazardFetchError.throttled(let retryAfter) {
            pause(retryAfter: retryAfter)
            return
        } catch HazardFetchError.status(let code) where (400..<500).contains(code) {
            requestRejected = true
            problem = "The National Weather Service did not accept the request (HTTP \(code)). "
                + "Check the alert area under the NWS Alerts switch."
            return
        } catch {
            requestRejected = false
            problem = "Could not reach the National Weather Service (\(error.localizedDescription)). "
                + (lastFetched == nil ? "No alerts have been fetched yet." : "Showing the alerts fetched earlier.")
            return
        }
        lastFetched = fetchedAt
        problem = nil
        requestRejected = false
        pausedUntil = nil
        consecutiveThrottles = 0
        var known = knownOutlines()
        for url in NWSAlertFeed.zonesToFetch(for: parsed, cached: Set(known.keys)).prefix(maxZonesPerRefresh) {
            await sleep(zonePause)
            let id = url.lastPathComponent
            let data: Data
            do {
                data = try await fetcher.data(for: NWSAlertFeed.zoneRequest(url))
            } catch HazardFetchError.throttled(let retryAfter) {
                pause(retryAfter: retryAfter)
                break
            } catch {
                continue
            }
            guard let zone = try? NWSAlertFeed.parseZone(data) else { continue }
            known[id] = zone
            try? cache.saveZone(id, data: data)
        }
        zonesStillLoading = NWSAlertFeed.zonesToFetch(for: parsed, cached: Set(known.keys)).count
        outlines = known
        let resolved = NWSAlertFeed.resolvingZones(parsed, outlines: known)
        unplacedCount = scope.unplaced(resolved)
        features = scope.keeping(resolved, near: point)
        // History is a record, not the display: a write that fails costs
        // the record, never the alerts on screen.
        try? history?.record(features)
    }

    /// The server asked us to slow down: its Retry-After when it gave one,
    /// else two minutes, doubling with each slow-down in a row up to
    /// `maxPause`.
    private func pause(retryAfter: TimeInterval?) {
        consecutiveThrottles += 1
        let doubling = Self.firstPause * pow(2, Double(consecutiveThrottles - 1))
        let until = now().addingTimeInterval(retryAfter ?? min(Self.maxPause, doubling))
        pausedUntil = until
        let time = until.formatted(date: .omitted, time: .shortened)
        problem = "The National Weather Service asked AXTerm to slow down. The next try is at \(time)."
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
    /// 429 or 503: the server asking us to slow down, with how long it
    /// asked us to wait when it said (`Retry-After`, in seconds).
    case throttled(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .status(let code): return "the server answered HTTP \(code)"
        case .notAllowed(let host): return "\(host) is not reachable from a test run"
        case .throttled: return "the server asked us to slow down"
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
            if http.statusCode == 429 || http.statusCode == 503 {
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After"))
                    .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                throw HazardFetchError.throttled(retryAfter: retryAfter)
            }
            throw HazardFetchError.status(http.statusCode)
        }
        return data
    }
}
