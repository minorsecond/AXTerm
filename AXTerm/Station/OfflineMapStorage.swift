import Foundation
import Combine
import MapKit

/// Owns the tile store and keeps its statistics fresh for the UI.
///
/// A thin observable wrapper on purpose: `MapTileStore` is a plain class with
/// no isolation so it can be read from MapKit's tile-loading threads, and
/// making *it* an `ObservableObject` would have meant a `@MainActor` type
/// being deallocated off the main actor — the same crash the offline snapshot
/// store hit before it was split the same way.
@MainActor
final class OfflineMapStorage: ObservableObject {

    @Published private(set) var statistics = MapTileStore.Statistics(
        tileCount: 0, byteSize: 0, minimumZoom: nil, maximumZoom: nil)
    @Published private(set) var openError: String?

    /// Nil when the store could not be opened. Offline mode is then hidden
    /// rather than offered and silently drawing nothing.
    private(set) var store: MapTileStore?
    let downloader: OfflineRegionDownloader

    private var cancellables: Set<AnyCancellable> = []

    nonisolated static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("AXTerm", isDirectory: true)
            .appendingPathComponent("basemap.mbtiles")
    }

    init(url: URL = OfflineMapStorage.defaultURL()) {
        let opened = try? MapTileStore(url: url)
        self.store = opened
        // A downloader with no store still exists so the UI has something to
        // bind to; every operation on it fails loudly rather than the view
        // having to handle a nil.
        self.downloader = OfflineRegionDownloader(store: opened ?? OfflineMapStorage.scratchStore())
        if opened == nil {
            openError = "The offline map store at \(url.path) could not be opened."
        }
        refresh()

        // Statistics are only interesting after something changed, and the
        // downloader's terminal states are exactly those moments.
        downloader.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                switch state {
                case .finished, .failed: self?.refresh()
                default: break
                }
            }
            .store(in: &cancellables)
    }

    func refresh() {
        guard let store else { return }
        statistics = (try? store.statistics()) ?? statistics
    }

    func deleteAll() {
        guard let store else { return }
        try? store.removeAllTiles()
        refresh()
    }

    /// Whether the offline basemap can actually draw something.
    ///
    /// The picker consults this: offering "Offline" with nothing stored
    /// produces a blank map that looks like a bug rather than an empty
    /// cupboard.
    var hasStoredTiles: Bool { statistics.tileCount > 0 }

    /// The provider whose tiles are stored, so attribution stays correct
    /// after an import from someone else's file.
    var storedSource: MapTileSource {
        guard let id = try? store?.metadata("axterm_source") ?? nil,
              let source = MapTileSource.source(id: id) else { return .imported }
        return source
    }

    /// A throwaway store in the temporary directory, used only so the
    /// downloader is non-optional when the real one failed to open.
    nonisolated private static func scratchStore() -> MapTileStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axterm-scratch-basemap.mbtiles")
        // Force-try is confined to a path that only runs when the real store
        // already failed; if the temporary directory is also unwritable there
        // is nothing left to degrade to.
        return try! MapTileStore(url: url)
    }
}
