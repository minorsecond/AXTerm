import Foundation
import MapKit

/// Draws the map from the local tile store, falling back to the network only
/// when the source allows it and a tile is genuinely missing.
///
/// `canReplaceMapContent = true` is what makes this a *real* offline map:
/// MapKit stops drawing its own basemap underneath, so what the operator sees
/// is exactly what is stored locally. Without it, MapKit would try to reach
/// Apple's servers for the base layer and the map would be blank in the field
/// no matter how many tiles had been downloaded.
nonisolated final class OfflineTileOverlay: MKTileOverlay, @unchecked Sendable {

    private let store: MapTileStore
    /// Which provider these tiles came from, so a view can tell whether the
    /// overlay it holds still matches the operator's chosen source.
    let tileSource: MapTileSource
    /// Tiles browsed online are written back, which is the caching every
    /// provider's policy permits and is how a source that forbids bulk
    /// download still ends up usable offline for the area actually worked.
    private let cachesBrowsedTiles: Bool
    private let session: URLSession

    init(store: MapTileStore, source: MapTileSource, cachesBrowsedTiles: Bool = true) {
        self.store = store
        self.tileSource = source
        self.cachesBrowsedTiles = cachesBrowsedTiles

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        // The tile store *is* the cache; a second one in URLSession would
        // double the disk cost for no benefit.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)

        super.init(urlTemplate: nil)

        self.canReplaceMapContent = true
        self.maximumZ = tileSource.maximumZoom
        self.minimumZ = 0
        self.tileSize = CGSize(width: 256, height: 256)
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let z = path.z, x = path.x, y = path.y

        if let local = try? store.tile(z: z, x: x, y: y) {
            result(local, nil)
            return
        }

        // Offline, or an imported file with no server behind it: report
        // nothing rather than an error. MapKit draws an empty tile, which
        // reads as "no data here" — the truth — instead of an alert the
        // operator can do nothing about.
        guard tileSource.isNetworkBacked, let url = tileSource.url(z: z, x: x, y: y) else {
            result(nil, nil)
            return
        }

        var request = URLRequest(url: url)
        // Every OSM-derived tile provider requires an identifying User-Agent
        // and blocks the default one.
        request.setValue("AXTerm/1.0 (packet radio terminal; +https://github.com/minorsecond/AXTerm)",
                         forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let data, !data.isEmpty,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                result(nil, error)
                return
            }
            if self?.cachesBrowsedTiles == true {
                try? self?.store.store([(z: z, x: x, y: y, data: data)])
            }
            result(data, nil)
        }.resume()
    }
}
