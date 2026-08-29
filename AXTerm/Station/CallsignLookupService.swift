import Foundation
import Combine

/// The app-facing callsign lookup: cache first, network second, and
/// everything it learns written back so the next lookup works offline.
///
/// The chain order is the whole policy. The cache is a `CallsignDirectory`
/// like any other and sits first, so a station looked up once stays
/// resolvable with the network gone — which is the only reason this is
/// worth having in a grid-down app at all.
///
/// **Opt-in.** Looking up a callsign tells a third party which stations
/// this operator is hearing. That is public licence data and a small
/// disclosure, but it is a disclosure, and it is not made silently.
@MainActor
final class CallsignLookupService: ObservableObject {

    /// Cached answers this session, so a table redrawing does not hit
    /// the store once per row per frame.
    @Published private(set) var records: [String: CallsignRecord] = [:]

    private let store: WinlinkStore?
    private let remote: any CallsignDirectory
    /// Whether network lookups are permitted. False leaves the service
    /// entirely cache-backed.
    var isNetworkEnabled: Bool

    /// While set in the future, no network lookup runs at all — the
    /// breaker a throttled or unreachable directory opens. Bulk callers
    /// check `isCoolingDown` and stop their pass instead of spinning
    /// through a list that cannot resolve.
    private var cooldownUntil: Date = .distantPast
    var isCoolingDown: Bool { cooldownUntil > Date() }
    /// How long one refusal silences the network. Five minutes is long
    /// enough to be polite and short enough that the map still fills in
    /// this session.
    var cooldownSeconds: TimeInterval = 300

    /// Callsigns already attempted this session, so a miss is not retried
    /// on every redraw.
    private var attempted = Set<String>()

    /// Records resolved during a quiet bulk pass, held out of the
    /// @Published dictionary until `flushStaged()`. Every publish
    /// re-renders every view observing this service — the whole
    /// ContentView tree, and through scene updates the menu-bar extra,
    /// which AppKit answers with an update-constraints storm when poked
    /// often enough (field capture 2026-08-29 06:12: the terminal froze
    /// at launch while the directory trickle published a record every
    /// couple of seconds).
    private var staged: [String: CallsignRecord] = [:]

    /// Publishes everything a quiet pass has accumulated, in one change.
    func flushStaged() {
        guard !staged.isEmpty else { return }
        records.merge(staged) { _, new in new }
        staged = [:]
    }

    init(store: WinlinkStore?,
         remote: any CallsignDirectory = HamDBDirectory(),
         isNetworkEnabled: Bool = false) {
        self.store = store
        self.remote = remote
        self.isNetworkEnabled = isNetworkEnabled
    }

    /// A record already in memory. Deliberately **non-mutating**: this is
    /// called from view bodies, and populating `@Published` state during
    /// a view update is exactly the "Publishing changes from within view
    /// updates" hazard. Use `preload(_:)` to fill memory from the store.
    func cached(_ callsign: String) -> CallsignRecord? {
        let key = CallsignQuery.normalize(callsign)
        return records[key] ?? staged[key]
    }

    /// Fills memory from the persistent cache. Call from `.task`, never
    /// from a view body.
    func preload(_ callsigns: [String]) {
        guard let store else { return }
        for callsign in callsigns {
            let key = CallsignQuery.normalize(callsign)
            guard records[key] == nil else { continue }
            guard let stored = try? store.callsignRecord(callsign: key) else { continue }
            records[key] = Self.record(from: stored)
        }
    }

    /// Resolves a callsign, consulting the network only if enabled and
    /// only if the cache has nothing. Returns nil for a miss.
    @discardableResult
    func resolve(_ callsign: String,
                 publishImmediately: Bool = true) async -> CallsignRecord? {
        let key = CallsignQuery.normalize(callsign)
        guard CallsignQuery.isPlausible(key) else { return nil }
        if let record = cached(key) { return record }
        // The persistent cache is still authoritative even if memory is
        // cold — check it before spending a network round trip.
        if let stored = try? store?.callsignRecord(callsign: key) {
            let record = Self.record(from: stored)
            if publishImmediately { records[key] = record } else { staged[key] = record }
            return record
        }
        guard isNetworkEnabled, !attempted.contains(key), !isCoolingDown
        else { return nil }
        attempted.insert(key)

        do {
            guard let record = try await remote.lookup(key) else { return nil }
            if publishImmediately { records[key] = record } else { staged[key] = record }
            // Write through so this survives the network going away.
            try? store?.saveCallsignRecord(Self.stored(from: record))
            return record
        } catch {
            // The directory refused or is unreachable. Open the breaker
            // and give this callsign back — it was never answered, so
            // "attempted" would wrongly turn a throttle into a miss.
            attempted.remove(key)
            cooldownUntil = Date().addingTimeInterval(cooldownSeconds)
            return nil
        }
    }

    /// Resolves several callsigns, skipping anything already known.
    /// Sequential on purpose: this is a courtesy query against someone
    /// else's free service, not a workload to parallelise.
    func resolveAll(_ callsigns: [String]) async {
        for callsign in callsigns {
            if isCoolingDown { return }
            _ = await resolve(callsign)
        }
    }

    // MARK: - Record mapping

    static func record(from stored: CallsignDirectoryRecord) -> CallsignRecord {
        CallsignRecord(
            callsign: stored.callsign,
            name: stored.name,
            gridSquare: stored.gridSquare,
            latitude: stored.latitude,
            longitude: stored.longitude,
            locality: stored.locality,
            state: stored.state,
            country: stored.country,
            licenseClass: stored.licenseClass,
            expires: stored.expires,
            source: stored.source,
            fetchedAt: stored.fetchedAt)
    }

    static func stored(from record: CallsignRecord) -> CallsignDirectoryRecord {
        CallsignDirectoryRecord(
            callsign: record.callsign,
            name: record.name,
            gridSquare: record.gridSquare,
            latitude: record.latitude,
            longitude: record.longitude,
            locality: record.locality,
            state: record.state,
            country: record.country,
            licenseClass: record.licenseClass,
            expires: record.expires,
            source: record.source,
            fetchedAt: record.fetchedAt)
    }
}
