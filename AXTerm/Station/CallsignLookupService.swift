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
    ///
    /// One store query and one publish for the whole list, however long it
    /// is. Both matter at the scale the node layer works at: the map places
    /// a directory node only if its operator's record is in `records`, so
    /// this is the step that decides whether hundreds of markers are on the
    /// map at launch or trickle back over the following minutes. Publishing
    /// per record would also re-render every observer once per callsign,
    /// which is the churn `flushStaged` exists to avoid.
    func preload(_ callsigns: [String]) {
        guard let store else { return }
        let wanted = Set(callsigns.map(CallsignQuery.normalize))
            .filter { !$0.isEmpty && records[$0] == nil && staged[$0] == nil }
        guard !wanted.isEmpty else { return }
        guard let stored = try? store.callsignRecords(callsigns: Array(wanted)) else { return }
        guard !stored.isEmpty else { return }
        var fetched: [String: CallsignRecord] = [:]
        for record in stored {
            fetched[CallsignQuery.normalize(record.callsign)] = Self.record(from: record)
        }
        records.merge(fetched) { existing, _ in existing }
    }

    /// Where an answer came from, so a caller pacing itself against someone
    /// else's free service can tell a network round trip from a local read.
    enum Origin: Equatable, Sendable {
        /// Already in memory, or read from this app's own cache.
        case cache
        /// A request actually went out to the remote directory.
        case network
        /// No answer: not cached, and the network was unavailable,
        /// disabled, already tried, or had nothing.
        case none
    }

    /// Resolves a callsign, consulting the network only if enabled and
    /// only if the cache has nothing. Returns nil for a miss.
    @discardableResult
    func resolve(_ callsign: String,
                 publishImmediately: Bool = true) async -> CallsignRecord? {
        await resolving(callsign, publishImmediately: publishImmediately).record
    }

    /// `resolve`, and where the answer came from.
    ///
    /// A bulk caller has to wait between *network* lookups and must not wait
    /// between cache reads: pausing on a local hit turned a four-second
    /// refill of the node layer into a four-minute one.
    @discardableResult
    func resolving(_ callsign: String,
                   publishImmediately: Bool = true)
    async -> (record: CallsignRecord?, origin: Origin) {
        let key = CallsignQuery.normalize(callsign)
        guard CallsignQuery.isPlausible(key) else { return (nil, .none) }
        if let record = cached(key) { return (record, .cache) }
        // The persistent cache is still authoritative even if memory is
        // cold — check it before spending a network round trip.
        if let stored = try? store?.callsignRecord(callsign: key) {
            let record = Self.record(from: stored)
            if publishImmediately { records[key] = record } else { staged[key] = record }
            return (record, .cache)
        }
        guard isNetworkEnabled, !attempted.contains(key), !isCoolingDown
        else { return (nil, .none) }
        attempted.insert(key)

        do {
            guard let record = try await remote.lookup(key) else { return (nil, .network) }
            if publishImmediately { records[key] = record } else { staged[key] = record }
            // Write through so this survives the network going away.
            try? store?.saveCallsignRecord(Self.stored(from: record))
            return (record, .network)
        } catch {
            // The directory refused or is unreachable. Open the breaker
            // and give this callsign back — it was never answered, so
            // "attempted" would wrongly turn a throttle into a miss.
            attempted.remove(key)
            cooldownUntil = Date().addingTimeInterval(cooldownSeconds)
            return (nil, .network)
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
