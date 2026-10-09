import Combine
import Foundation
import GRDB

/// Runs the hazard layers for the map: the app ticks it on a timer, and it
/// fetches only when `HazardRefreshPolicy` says so. A layer that is off is
/// not drawn and not fetched; its last copy stays on disk for when it is
/// turned back on.
@MainActor
final class HazardLayerController: ObservableObject {
    let nws: NWSAlertLayer

    /// Whether the NWS layer is on, as of the last tick.
    @Published private(set) var nwsEnabled = false

    private let now: () -> Date
    private var lastAttempt: Date?
    private var lastPoint: GreatCircle.Point?
    private var lastScope: NWSAlertScope?
    private var cancellable: AnyCancellable?

    init(nws: NWSAlertLayer, now: @escaping () -> Date = Date.init) {
        self.nws = nws
        self.now = now
        // The map redraws when the layer's alerts change.
        cancellable = nws.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// What the map draws: the layer's alerts while it is on, nothing off.
    var drawnFeatures: [HazardFeature] { nwsEnabled ? nws.features : [] }

    func tick(nwsEnabled enabled: Bool, position: GreatCircle.Point?) async {
        await tick(nwsEnabled: enabled, scope: .here, position: position)
    }

    func tick(nwsEnabled enabled: Bool, scope: NWSAlertScope, position: GreatCircle.Point?) async {
        if enabled != nwsEnabled {
            nwsEnabled = enabled
            // Back on: show the saved copy, at its real age, until a fetch.
            if enabled, nws.features.isEmpty { nws.loadCached() }
        }
        guard HazardRefreshPolicy.shouldRefresh(enabled: enabled, position: position,
                                                lastAttempt: lastAttempt, lastPoint: lastPoint, now: now(),
                                                needsPosition: scope.needsPosition,
                                                scopeChanged: lastScope.map { $0 != scope } ?? false)
        else { return }
        lastAttempt = now()
        lastPoint = position
        lastScope = scope
        await nws.refresh(scope, at: position)
    }

    /// Where the hazard layers keep their last good copy: Application
    /// Support for a normal install, and a folder of its own for a test-mode
    /// instance, apart from the operator's install and from other instances.
    static func cacheDirectory(testInstance: String?, applicationSupport: URL, temporary: URL) -> URL {
        guard let testInstance else {
            return applicationSupport.appendingPathComponent("AXTerm", isDirectory: true)
                .appendingPathComponent("Hazards", isDirectory: true)
        }
        let name = testInstance.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return temporary.appendingPathComponent(DatabaseManager.ephemeralFolderName, isDirectory: true)
            .appendingPathComponent("hazards-\(name)", isDirectory: true)
    }

    /// The controller an app runs: URLSession for the feeds, the cache
    /// folder above, and history in the station database when there is one.
    static func make(database: DatabaseQueue?) -> HazardLayerController {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = cacheDirectory(
            testInstance: AppEnvironment.isTestMode ? TestModeConfiguration.shared.instanceID : nil,
            applicationSupport: support, temporary: FileManager.default.temporaryDirectory)
        let nws = NWSAlertLayer(fetcher: URLSessionHazardFetcher(), cache: HazardDiskCache(directory: directory),
                                history: database.map { SQLiteHazardHistoryStore(dbQueue: $0) })
        return HazardLayerController(nws: nws)
    }

    /// What the app runs while it is open: every 15 seconds, read the
    /// layer's switch and tick. `HazardRefreshPolicy` decides whether a tick
    /// fetches, so this costs nothing while the layer is off.
    func run(position: @escaping @MainActor () -> GreatCircle.Point?, status: MapLayerStatus) async {
        while !Task.isCancelled {
            let enabled = AppEnvironment.defaults.object(forKey: "stations.showsNWSAlerts") as? Bool
                ?? MapLayerDefaults.showsNWSAlerts
            let scope = NWSAlertScope(stored: AppEnvironment.defaults.string(forKey: NWSAlertScope.storageKey) ?? "")
            await tick(nwsEnabled: enabled, scope: scope, position: position())
            status.nwsCaption = nwsCaption()
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    /// The caption under the NWS layer's switch, or nil while it is off.
    func nwsCaption(now: Date = Date()) -> String? {
        guard nwsEnabled else { return nil }
        return HazardText.layerCaption(count: nws.features.count, lastFetched: nws.lastFetched,
                                       problem: nws.problem, stale: nws.isStale, now: now)
    }

    /// The station's position as the map draws it, read from the settings
    /// and the device's fix each time it is called. Never through a copy of
    /// a view: one captured when the loop started kept fetching Colorado's
    /// alerts after the position moved to Alabama (2026-10-09).
    static func livePosition(defaults: UserDefaults,
                             deviceLocation: @escaping @MainActor () -> StationLocation?)
        -> @MainActor () -> GreatCircle.Point? {
        {
            StationPositionResolver.ownStation(defaults: defaults, deviceLocation: deviceLocation())?.point
        }
    }
}
