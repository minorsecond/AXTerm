import SwiftUI
import MapKit
import CoreLocation
import UniformTypeIdentifiers

/// Managing the stored basemap: what is on this device, how to get more, and
/// how much room it takes.
///
/// Two ways to get a map: download a region from a source whose terms allow it
/// — USGS, which is public-domain federal data and also the right map for
/// judging an RF path — or import an `.mbtiles` file. The picker separates
/// sources that can be downloaded from those that can only be browsed, so the
/// operator does not discover by trial which ones refuse.
struct OfflineMapsView: View {

    @ObservedObject var store: OfflineMapStorage
    /// Elevation grids, offered alongside the basemap because they answer
    /// the same operator question from the other side: the basemap shows
    /// where a ridge is, this says whether it is in the way.
    @ObservedObject var elevation: ElevationStorage
    /// The operator's own position. Terrain is fetched around *this*, never
    /// around a bounding box of everyone heard — one distant station makes
    /// that box a continent.
    var observer: GreatCircle.Point?
    /// A region the operator drew on the map. When present it is what both
    /// downloads act on — they asked for exactly this box, and second-guessing
    /// it with a radius around their station would be answering a different
    /// question.
    var drawnRegion: MKCoordinateRegion?
    /// Region to offer for download — normally what the operator is looking
    /// at. Nil disables the download section rather than defaulting to
    /// somewhere arbitrary.
    var suggestedRegion: MKCoordinateRegion?
    var suggestedRegionName: String = "the current map view"

    /// Defaults to a source that can actually be downloaded from. Opening on
    /// one that refuses made the whole section look broken.
    @State private var selectedSource: MapTileSource = .usgsTopo
    @State private var zoomRange: ClosedRange<Int> = 8...13
    @State private var isPickingFile = false
    @State private var confirmation: DownloadConfirmation?

    var body: some View {
        Form {
            storedSection
            importSection
            if suggestedRegion != nil { downloadSection }
            terrainSection
            statusSection
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isPickingFile,
                      allowedContentTypes: Self.mbtilesTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.downloader.importMBTiles(from: url)
            }
        }
        // One alert, not two.
        //
        // SwiftUI honours a single `.alert` per view for the same reason it
        // honours a single `.sheet`: the last one wins and the earlier one
        // silently never presents. Adding a terrain confirmation below the
        // basemap one is why "Download this area" stopped doing anything at
        // all — the button set its state and no alert ever appeared.
        .alert(item: $confirmation) { confirmation in
            Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text("Download")) {
                    switch confirmation.kind {
                    case .basemap: startDownload(confirmed: true)
                    case .terrain:
                        if let drawnRegion {
                            elevation.download(covering: drawnRegion)
                        } else if let observer {
                            elevation.download(around: observer)
                        }
                    }
                },
                secondaryButton: .cancel())
        }
    }

    private static func terrainConfirmation(_ estimate: ElevationStorage.Estimate)
        -> DownloadConfirmation {
        DownloadConfirmation(
            kind: .terrain,
            title: "Large terrain download",
            message: "This fetches \(estimate.tileCount) elevation tiles, about "
                + "\(estimate.sizeDescription), one request at a time from a public "
                + "USGS service.")
    }

    private static func basemapConfirmation(_ estimate: OfflineRegionDownloader.Estimate)
        -> DownloadConfirmation {
        DownloadConfirmation(
            kind: .basemap,
            title: "Large download",
            message: "This covers \(estimate.tileCount.formatted()) tiles, roughly "
                + "\(estimate.sizeDescription). That is a lot of requests to a "
                + "community server and a lot of space on this device. Importing an "
                + ".mbtiles file is faster and easier on the provider.")
    }

    /// What the single confirmation alert is asking about.
    struct DownloadConfirmation: Identifiable {
        enum Kind { case basemap, terrain }
        let kind: Kind
        let title: String
        let message: String
        var id: String { title + message }
    }

    // MARK: - Sections

    private var storedSection: some View {
        Section("On this device") {
            LabeledContent("Stored tiles") {
                Text(store.statistics.tileCount.formatted())
                    .monospacedDigit()
            }
            .explain("How many map tiles this device holds. Each covers one square of one zoom level; a town at street detail is a few thousand, a state at terrain detail is tens of thousands.")

            LabeledContent("Space used") {
                Text(store.statistics.sizeDescription)
                    .monospacedDigit()
            }

            if let minZoom = store.statistics.minimumZoom,
               let maxZoom = store.statistics.maximumZoom {
                LabeledContent("Detail") {
                    Text("z\(minZoom)–z\(maxZoom)")
                        .monospacedDigit()
                }
                .explain("The zoom levels stored. Roughly: z8 shows a region, z11 a county, z14 a street layout. Zooming past the highest stored level shows blank tiles rather than guessing.")
            }

            if store.statistics.tileCount > 0 {
                Button("Delete Stored Map", role: .destructive) {
                    store.deleteAll()
                }
                .explain("Removes every stored tile and reclaims the space. The map stops working offline until something is stored again.")
            } else {
                Text("No offline map stored. The map needs a network until one is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Elevation coverage, and a way to get it for the area on screen.
    ///
    /// Deliberately plain about what it buys: terrain data is what turns
    /// "this station never answers" into "there is a ridge 40 m above the
    /// line 8 km out". Without it the terrain features are unavailable
    /// rather than guessing.
    private var terrainSection: some View {
        Section("Terrain") {
            LabeledContent("Stored") {
                Text(elevation.tileCount == 0
                     ? "None"
                     : "\(elevation.tileCount) tile\(elevation.tileCount == 1 ? "" : "s") \u{00B7} "
                        + ByteCount.string(elevation.byteSize))
                    .foregroundStyle(.secondary)
            }
            .help("Elevation grids covering one degree of latitude and longitude each, about 100 m between samples. A path profile normally touches one or two tiles.")


            if elevation.downloader == nil {
                Text("The elevation store could not be opened, so terrain analysis is unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .downloading(let done, let total) = elevation.downloadState {
                HStack {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text("\(done) of \(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Cancel") { elevation.cancelDownload() }
                        .buttonStyle(.borderless)
                }
            } else if let drawnRegion {
                let estimate = elevation.estimate(covering: drawnRegion)
                Button {
                    if estimate.tileCount > ElevationDownloader.largeRegionTileCount {
                        confirmation = Self.terrainConfirmation(estimate)
                    } else {
                        elevation.download(covering: drawnRegion)
                    }
                } label: {
                    Label("Download Terrain for This Area", systemImage: "mountain.2")
                }
                .disabled(estimate.tileCount == 0)
                .help("Fetches USGS 3DEP elevation for the box you drew \u{2014} public-domain federal data, no account needed. Tiles are one degree square, so the download covers whole tiles wherever the box crosses them.")

                Text(terrainSummary(estimate))
                    .font(.caption)
                    .foregroundStyle(estimate.wasCapped ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let observer {
                let estimate = elevation.estimate(around: observer)
                Button {
                    if estimate.tileCount > ElevationDownloader.largeRegionTileCount {
                        confirmation = Self.terrainConfirmation(estimate)
                    } else {
                        elevation.download(around: observer)
                    }
                } label: {
                    Label("Download Terrain Around My Station", systemImage: "mountain.2")
                }
                .disabled(estimate.tileCount == 0)
                .help("Fetches USGS 3DEP elevation for the ground within about 120 km of your station \u{2014} public-domain federal data, no account needed. That radius is deliberate: it is the range beyond which path forecasts stop looking, so anything further answers no question the app asks. To choose a different area, draw one on the map with the Download tool.")

                Text(terrainSummary(estimate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Set your grid square first \u{2014} terrain is fetched around your station, so it needs to know where that is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = elevation.downloadState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if elevation.tileCount > 0 {
                Button("Delete Terrain Data", role: .destructive) {
                    elevation.deleteAll()
                }
                .help("Removes every stored elevation tile. Path profiles and terrain forecasts stop working until some are downloaded again.")
            }
        }
    }

    /// States the cost, and says out loud when a cap trimmed the request.
    ///
    /// A cap the operator cannot see reads as coverage they did not get —
    /// they would come back from the field wondering why the far half of the
    /// box has no terrain.
    private func terrainSummary(_ estimate: ElevationStorage.Estimate) -> String {
        guard estimate.tileCount > 0 else {
            return "Everything in this area is already stored."
        }
        let base = "\(estimate.tileCount) tile\(estimate.tileCount == 1 ? "" : "s") "
            + "to fetch, about \(estimate.sizeDescription)."
        guard estimate.wasCapped else { return base }
        return base + " That area covers \(estimate.requestedTileCount) tiles, "
            + "more than the \(ElevationStorage.maximumTilesPerRequest) one request "
            + "will fetch \u{2014} the nearest part is downloaded, so draw a smaller "
            + "box for the rest."
    }

    private var importSection: some View {
        Section("Import a map file") {
            Text("An .mbtiles file holds a whole region's tiles in one file. Use this for coverage AXTerm cannot fetch itself — outside the US, or a basemap you generated yourself.\n\nMust be raster tiles (PNG or JPEG). Vector files — anything described as vector tiles, PMTiles or OpenMapTiles — are refused rather than imported blank.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                isPickingFile = true
            } label: {
                Label("Choose .mbtiles File…", systemImage: "square.and.arrow.down")
            }
            .disabled(store.downloader.state.isBusy)
        }
    }

    private var downloadSection: some View {
        Section("Download a region") {
            Picker("Source", selection: $selectedSource) {
                // Downloadable sources first and under their own heading: the
                // others are here so the refusal is explicable, not so the
                // operator has to discover by trial which ones work.
                Section("Can be downloaded") {
                    ForEach(MapTileSource.downloadable) { source in
                        Text(source.name).tag(source)
                    }
                }
                Section("Browse only") {
                    ForEach(MapTileSource.all.filter { $0.isNetworkBacked && !$0.permitsBulkDownload }) { source in
                        Text(source.name).tag(source)
                    }
                }
            }
            .explain(selectedSource.summary)

            if !selectedSource.permitsBulkDownload, let note = selectedSource.bulkDownloadNote {
                Label(note, systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Detail") {
                HStack(spacing: 4) {
                    Stepper("z\(zoomRange.lowerBound)", value: Binding(
                        get: { zoomRange.lowerBound },
                        set: { zoomRange = min($0, zoomRange.upperBound)...zoomRange.upperBound }),
                            in: 1...18)
                    Stepper("z\(zoomRange.upperBound)", value: Binding(
                        get: { zoomRange.upperBound },
                        set: { zoomRange = zoomRange.lowerBound...max($0, zoomRange.lowerBound) }),
                            in: 1...18)
                }
            }
            .explain("Zoom levels to store, lowest to highest. Every extra level roughly quadruples the tile count, so the top of the range is what decides the size. z8–z13 covers 'see the region' to 'see the roads'.")

            if let region = suggestedRegion {
                let estimate = OfflineRegionDownloader.estimate(region: region, zoomRange: zoomRange)
                LabeledContent("Estimated size") {
                    Text("\(estimate.tileCount.formatted()) tiles · about \(estimate.sizeDescription)")
                        .font(.caption)
                        .monospacedDigit()
                }
                .explain("An estimate from an average tile size, not a measurement — the real total depends on how much detail is in the area. Empty country is far smaller than a city.")
            }

            Button {
                startDownload(confirmed: false)
            } label: {
                Label("Download \(suggestedRegionName)", systemImage: "arrow.down.circle")
            }
            .disabled(store.downloader.state.isBusy || !selectedSource.permitsBulkDownload)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch store.downloader.state {
        case .idle:
            EmptyView()
        case .estimating:
            Section { Label("Working out what is needed…", systemImage: "hourglass") }
        case .downloading(let completed, let total):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    HStack {
                        Text("\(completed.formatted()) of \(total.formatted()) tiles")
                            .font(.caption)
                            .monospacedDigit()
                        Spacer()
                        Button("Stop") { store.downloader.cancel() }
                            .controlSize(.small)
                    }
                }
                // Stopping keeps what has already been stored: a partial
                // download is a partial map, not a wasted one.
                .explain("Tiles already stored are kept if you stop. The download resumes from where it left off rather than starting again.")
            }
        case .importing:
            Section { Label("Importing…", systemImage: "square.and.arrow.down") }
        case .finished(let tiles, _):
            Section {
                Label(tiles == 0 ? "Already stored — nothing new to fetch."
                                 : "Stored \(tiles.formatted()) tiles.",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .refused(let reason):
            Section {
                Label(reason, systemImage: "hand.raised")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func startDownload(confirmed: Bool) {
        guard let region = suggestedRegion else { return }
        let estimate = OfflineRegionDownloader.estimate(region: region, zoomRange: zoomRange)
        if estimate.isLarge && !confirmed {
            confirmation = Self.basemapConfirmation(estimate)
            return
        }
        store.downloader.download(region: region, zoomRange: zoomRange, source: selectedSource)
    }

    /// `.mbtiles` has no registered UTI, so it is matched by filename
    /// extension with a data fallback — otherwise the picker greys out the
    /// only files it is meant to accept.
    private static var mbtilesTypes: [UTType] {
        [UTType(filenameExtension: "mbtiles") ?? .database, .data]
    }
}

// MARK: - Overlay layers

/// Loads and toggles boundary overlays.
///
/// A menu rather than a sheet: adding a layer is one file pick, and after
/// that the operator only wants to switch layers on and off — which is a
/// glance and a click, not a dialog.
struct MapOverlayControl: View {

    @ObservedObject var store: MapOverlayStore
    /// Where a new mark goes — normally the observer's own position. Nil
    /// hides the action rather than dropping a mark at latitude zero.
    var markCoordinate: CLLocationCoordinate2D?
    /// Creates a Winlink draft from a layer. Nil hides the send action —
    /// without a mailbox there is nothing to send into.
    var onSendViaWinlink: ((MapOverlayLayer, MapOverlayExport.Format) -> Void)?
    @State private var isPickingFile = false
    @State private var pendingExport: ExportableFile?
    @State private var prompt: TextEntryPrompt?

    var body: some View {
        Menu {
            if store.layers.isEmpty {
                Text("No boundary layers loaded")
            } else {
                ForEach(store.layers) { layer in
                    Toggle(isOn: Binding(
                        get: { layer.isVisible },
                        set: { store.setVisible($0, for: layer) })) {
                        Text("\(layer.name) (\(layer.featureCount))")
                    }
                }
                Divider()
                Button("Remove All", role: .destructive) {
                    for layer in store.layers { store.remove(layer) }
                }
            }

            Divider()
            if let markCoordinate {
                Button("Add Mark Here…") {
                    prompt = TextEntryPrompt(
                        id: "mark",
                        title: "Add Mark",
                        message: "Name this position. It is saved to “\(MapOverlayStore.scratchLayerName)” on this device and can be exported or sent later.",
                        placeholder: "Staging area",
                        confirmTitle: "Add") { name in
                            store.addPoint(at: markCoordinate, name: name)
                        }
                }
            }
            Button("Add Shapefile or GeoJSON…") { isPickingFile = true }

            if !store.layers.isEmpty {
                Menu("Export") {
                    ForEach(store.layers) { layer in
                        Menu(layer.name) {
                            Button("Save as GeoJSON…") { export(layer, as: .geoJSON) }
                            Button("Save as Shapefile (.zip)…") { export(layer, as: .shapefile) }
                            if let onSendViaWinlink {
                                Divider()
                                // GeoJSON only over the air: it is text, so
                                // LZHUF compresses it, where a zipped
                                // shapefile is already compressed and gains
                                // nothing for several times the size.
                                Button("Send via Winlink (GeoJSON)…") {
                                    onSendViaWinlink(layer, .geoJSON)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(store.visibleLayers.isEmpty ? "Boundaries"
                                              : "Boundaries (\(store.visibleLayers.count))",
                  systemImage: "square.on.square.dashed")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Draw county lines, ARES districts, evacuation zones or any other boundary over the map. Reads ESRI shapefiles (.shp) and GeoJSON. Layers stay on this device and work offline.")
        .fileImporter(isPresented: $isPickingFile,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { load(urls) }
        }
        .exportFile($pendingExport) { store.lastError = $0 }
        .textEntryPrompt($prompt)
        .alert("Layer not added", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    /// Writes a layer out in the chosen format.
    ///
    /// Failure is surfaced rather than swallowed: an export the operator
    /// asked for and did not get is worse than one that visibly refused,
    /// because they will assume they have the file.
    private func export(_ layer: MapOverlayLayer, as format: MapOverlayExport.Format) {
        do {
            let data: Data
            switch format {
            case .geoJSON: data = try store.exportGeoJSON(layer)
            case .shapefile: data = try store.exportShapefile(layer)
            }
            pendingExport = ExportableFile(
                name: MapOverlayExport.filename(layer: layer, format: format), data: data)
        } catch let error as ShapefileWriter.WriteError {
            store.lastError = error.explanation
        } catch {
            store.lastError = "\(layer.name) could not be exported: \(error.localizedDescription)"
        }
    }

    /// Reads each picked file, looking for a companion `.prj` beside a `.shp`.
    ///
    /// A shapefile carries no coordinate system in the `.shp` itself, so the
    /// `.prj` is the only thing that says whether these numbers are degrees.
    /// Without it a projected file is read as latitude/longitude and every
    /// feature lands thousands of miles away — with no error at all.
    private func load(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else {
                store.lastError = "\(url.lastPathComponent) could not be read."
                continue
            }

            var projection: String?
            if url.pathExtension.lowercased() == "shp" {
                let prj = url.deletingPathExtension().appendingPathExtension("prj")
                projection = try? String(contentsOf: prj, encoding: .utf8)
            }

            store.add(data: data, filename: url.lastPathComponent, projectionWKT: projection)
        }
    }
}
