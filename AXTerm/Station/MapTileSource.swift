import Foundation

/// Where offline tiles come from, and what each provider permits.
///
/// The terms are encoded rather than documented because they constrain what
/// the app may actually do. OpenStreetMap's own tile servers, for example,
/// are run on donated hardware and their usage policy explicitly forbids bulk
/// downloading; an app that quietly pulled 50,000 tiles from them would be
/// abusing a volunteer service. So `permitsBulkDownload` is a property of the
/// source, the downloader refuses sources that say no, and the UI explains
/// why rather than presenting a button that misbehaves.
///
/// The path that is unambiguously allowed everywhere is importing an
/// `.mbtiles` file the operator obtained themselves — see
/// `MapTileSource.imported`. That is also the path that scales to a whole
/// state, so it is presented first rather than as a fallback.
nonisolated struct MapTileSource: Identifiable, Hashable, Sendable {

    let id: String
    let name: String
    /// One line on what this basemap is good for.
    let summary: String
    /// `{z}`, `{x}`, `{y}` template. Nil for an imported file, which has no
    /// server behind it.
    let urlTemplate: String?
    /// Required by the licence and shown on every map that draws these tiles.
    let attribution: String
    /// Beyond this the provider has no tiles; asking anyway wastes the
    /// request and returns an error the operator would have to interpret.
    let maximumZoom: Int
    /// Whether the provider's terms allow downloading a region for offline
    /// use. False is not a technical limit — it is a term of service.
    let permitsBulkDownload: Bool
    /// Stated when bulk download is refused, so the refusal is explicable.
    let bulkDownloadNote: String?

    // MARK: - Built-in sources

    /// An `.mbtiles` file the operator supplied.
    ///
    /// The best answer to "truly offline": no server, no terms to breach, no
    /// download to sit through, and whole-country files are freely available
    /// from OpenStreetMap-derived projects.
    static let imported = MapTileSource(
        id: "imported",
        name: "Imported file",
        summary: "An .mbtiles file you downloaded yourself. Nothing is fetched over the network, and a whole state fits in one file.",
        urlTemplate: nil,
        attribution: "© OpenStreetMap contributors (or as stated by the file's producer)",
        maximumZoom: 20,
        permitsBulkDownload: true,
        bulkDownloadNote: nil)

    /// USGS National Map — topographic.
    ///
    /// The answer to "where do I download from, then". USGS basemaps are US
    /// federal government work: **public domain**, free to use, no API key,
    /// and no policy against retrieving a region in advance. For a US
    /// packet-radio app they are also the *right* map — the 7.5-minute topo
    /// series is what shows the ridge between two stations.
    ///
    /// Zoom limits verified against the live service rather than the
    /// published metadata, which claims levels 0–23 while the tile endpoint
    /// returns 404 above 16.
    ///
    /// ArcGIS orders its tile path row-before-column, hence `{z}/{y}/{x}`.
    /// Getting that backwards returns tiles from entirely the wrong place —
    /// plausible-looking terrain, hundreds of miles away.
    static let usgsTopo = MapTileSource(
        id: "usgs-topo",
        name: "USGS Topo",
        summary: "US Geological Survey topographic maps — contours, terrain, hydrography. Public domain, and downloadable for offline use.",
        urlTemplate: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}",
        attribution: "USGS The National Map \u{00B7} public domain",
        maximumZoom: 16,
        permitsBulkDownload: true,
        bulkDownloadNote: nil)

    /// USGS National Map — imagery with topographic overlay.
    static let usgsImagery = MapTileSource(
        id: "usgs-imagery",
        name: "USGS Imagery + Topo",
        summary: "Aerial imagery with topographic lines over it. Public domain, and downloadable for offline use.",
        urlTemplate: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryTopo/MapServer/tile/{z}/{y}/{x}",
        attribution: "USGS The National Map \u{00B7} public domain",
        maximumZoom: 16,
        permitsBulkDownload: true,
        bulkDownloadNote: nil)

    /// USGS National Map — shaded relief only.
    ///
    /// Coarse (nothing above zoom 13) but tiny, so a whole state of terrain
    /// shading costs very little. Useful as the wide-area layer under a
    /// smaller, more detailed download.
    static let usgsRelief = MapTileSource(
        id: "usgs-relief",
        name: "USGS Shaded Relief",
        summary: "Terrain shading with nothing else on it. Coarse but very small \u{2014} a whole state costs little.",
        urlTemplate: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSShadedReliefOnly/MapServer/tile/{z}/{y}/{x}",
        attribution: "USGS The National Map \u{00B7} public domain",
        maximumZoom: 13,
        permitsBulkDownload: true,
        bulkDownloadNote: nil)

    /// OpenTopoMap — contour lines and terrain shading.
    ///
    /// The most useful basemap for this app by a distance: what decides
    /// whether a VHF path works is the ridge between two stations, and this
    /// is the only free source that draws it. Their tile server is a small
    /// volunteer operation, so bulk download is off.
    static let openTopo = MapTileSource(
        id: "opentopo",
        name: "OpenTopoMap",
        summary: "Contours and terrain shading — the basemap that actually shows why a path does or does not work.",
        urlTemplate: "https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png",
        attribution: "Map data © OpenStreetMap contributors, SRTM · Style © OpenTopoMap (CC-BY-SA)",
        maximumZoom: 17,
        permitsBulkDownload: false,
        bulkDownloadNote: "OpenTopoMap runs on donated hardware and asks that tiles not be bulk-downloaded. AXTerm caches what you browse, which their policy allows, but will not pull a region in advance. For offline terrain, import an .mbtiles file instead.")

    /// OpenStreetMap standard tiles.
    static let openStreetMap = MapTileSource(
        id: "osm",
        name: "OpenStreetMap",
        summary: "Roads, tracks and place names. Good for getting to a site; poor for judging a path.",
        urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
        attribution: "© OpenStreetMap contributors",
        maximumZoom: 19,
        permitsBulkDownload: false,
        bulkDownloadNote: "The OpenStreetMap Foundation's tile usage policy forbids bulk downloading from their servers. AXTerm caches tiles you actually browse, which is permitted, but will not download a region in advance. For offline coverage, import an .mbtiles file.")

    static let all: [MapTileSource] = [
        .imported, .usgsTopo, .usgsImagery, .usgsRelief, .openTopo, .openStreetMap,
    ]

    /// Sources a region can actually be downloaded from. What the picker
    /// should offer first, rather than making the operator discover by
    /// trial which ones refuse.
    static var downloadable: [MapTileSource] {
        all.filter { $0.isNetworkBacked && $0.permitsBulkDownload }
    }

    static func source(id: String) -> MapTileSource? {
        all.first { $0.id == id }
    }

    // MARK: - URLs

    /// Subdomains for providers that shard across `a.`/`b.`/`c.`.
    ///
    /// Chosen deterministically from the tile's own coordinates rather than
    /// at random, so the same tile always goes to the same host and any
    /// intermediate cache actually hits.
    private static let subdomains = ["a", "b", "c"]

    func url(z: Int, x: Int, y: Int) -> URL? {
        guard let urlTemplate else { return nil }
        let subdomain = Self.subdomains[abs(x &+ y) % Self.subdomains.count]
        let filled = urlTemplate
            .replacingOccurrences(of: "{s}", with: subdomain)
            .replacingOccurrences(of: "{z}", with: String(z))
            .replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(y))
        return URL(string: filled)
    }

    /// Whether this source can serve a tile at all — an imported file has no
    /// server, so browsing beyond what it contains shows nothing rather than
    /// silently fetching.
    var isNetworkBacked: Bool { urlTemplate != nil }
}
