import Foundation
import Combine
import CoreLocation

/// The overlay layers on this device, and where they live between launches.
///
/// Persisted as **GeoJSON files** rather than rows in the database. Three
/// reasons, in order of how much they matter:
///
/// 1. A layer is worth nothing if it vanishes on quit. An operator who loaded
///    county boundaries before an activation needs them during it, and the
///    activation is the part where nobody has a spare hand to re-import
///    anything.
/// 2. GeoJSON is the same format the operator exports and sends. One writer,
///    one reader, and the file on disk is already the file to attach — no
///    separate serialisation to keep in step with the one that goes over the
///    air.
/// 3. A layer is a file the operator brought. Keeping it as a file means they
///    can take it away again, and means a corrupt layer costs one file rather
///    than the mailbox it would have shared a database with.
///
/// Device-local and **not** synced: an overlay is a working file for one
/// activation, often megabytes, and pushing a county-boundary shapefile
/// through the mailbox's sync channel would be expensive for no gain. Same
/// reasoning as everything else in `Docs/UnifiedMailbox.md` §2 that describes
/// this device rather than the operator.
@MainActor
final class MapOverlayStore: ObservableObject {

    @Published private(set) var layers: [MapOverlayLayer] = []
    @Published var lastError: String?

    var visibleLayers: [MapOverlayLayer] { layers.filter(\.isVisible) }

    /// Name of the layer new features are added to, created on first use.
    static let scratchLayerID = "axterm-marks.geojson"
    static let scratchLayerName = "My Marks"

    private let directory: URL

    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("AXTerm", isDirectory: true)
            .appendingPathComponent("Overlays", isDirectory: true)
    }

    init(directory: URL = MapOverlayStore.defaultDirectory()) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Persistence

    /// Reads every stored layer.
    ///
    /// A file that will not parse is reported and skipped rather than
    /// stopping the load: one bad layer must not cost the operator the other
    /// five, and they need to know which one to replace.
    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []

        var loaded: [MapOverlayLayer] = []
        var failures: [String] = []

        for file in files.filter({ $0.pathExtension.lowercased() == "geojson" }).sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            guard let data = try? Data(contentsOf: file) else {
                failures.append(file.lastPathComponent)
                continue
            }
            do {
                let features = try MapOverlayLoader.readGeoJSON(data, filename: file.lastPathComponent)
                let meta = Self.readSidecar(for: file)
                loaded.append(MapOverlayLayer(
                    id: file.lastPathComponent,
                    name: meta.name ?? (file.deletingPathExtension().lastPathComponent),
                    features: features,
                    colorName: meta.colorName ?? MapOverlayLayer.color(forIndex: loaded.count),
                    isVisible: meta.isVisible ?? true,
                    isEditable: file.lastPathComponent == Self.scratchLayerID))
            } catch {
                failures.append(file.lastPathComponent)
            }
        }

        layers = loaded
        if !failures.isEmpty {
            lastError = "Could not read: \(failures.joined(separator: ", ")). Those layers were skipped; the rest loaded."
        }
    }

    /// Writes one layer, and its display settings beside it.
    ///
    /// Failure is surfaced. A layer that silently failed to save looks
    /// identical to one that saved — until the next launch, which is
    /// invariably the activation.
    private func persist(_ layer: MapOverlayLayer) {
        do {
            let data = try GeoJSONWriter.data(for: layer)
            try data.write(to: directory.appendingPathComponent(layer.id), options: .atomic)
            Self.writeSidecar(for: layer, in: directory)
        } catch {
            lastError = "\(layer.name) could not be saved: \(error.localizedDescription)"
        }
    }

    /// Colour and visibility, kept beside the GeoJSON rather than inside it.
    ///
    /// The `.geojson` stays a clean, standard file that any other tool can
    /// open — putting AXTerm's display preferences in its properties would
    /// make every exported file carry app-specific noise.
    private struct Sidecar: Codable {
        var name: String?
        var colorName: String?
        var isVisible: Bool?
    }

    private static func sidecarURL(for id: String, in directory: URL) -> URL {
        directory.appendingPathComponent(id + ".display.json")
    }

    private static func readSidecar(for file: URL) -> Sidecar {
        let url = sidecarURL(for: file.lastPathComponent, in: file.deletingLastPathComponent())
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data)
        else { return Sidecar() }
        return sidecar
    }

    private static func writeSidecar(for layer: MapOverlayLayer, in directory: URL) {
        let sidecar = Sidecar(name: layer.name, colorName: layer.colorName,
                              isVisible: layer.isVisible)
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? data.write(to: sidecarURL(for: layer.id, in: directory), options: .atomic)
    }

    // MARK: - Adding files

    func add(data: Data, filename: String, projectionWKT: String? = nil) {
        do {
            let loaded = try MapOverlayLoader.load(
                data: data, filename: filename, projectionWKT: projectionWKT,
                colorName: MapOverlayLayer.color(forIndex: layers.count))
            // Stored under a .geojson name whatever came in, because that is
            // the format on disk. A shapefile is converted once, on import,
            // rather than re-parsed on every launch.
            let stem = (filename as NSString).deletingPathExtension
            var layer = loaded
            layer = MapOverlayLayer(id: stem + ".geojson", name: stem,
                                    features: loaded.features,
                                    colorName: loaded.colorName,
                                    isVisible: true, isEditable: false)

            layers.removeAll { $0.id == layer.id }
            layers.append(layer)
            persist(layer)
            lastError = nil
        } catch let error as MapOverlayLoader.LoadError {
            lastError = error.explanation
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Imports spatial data that arrived in a message.
    ///
    /// Nothing is imported implicitly — a layer appearing because a message
    /// arrived would be a stranger drawing on the operator's situational
    /// picture. This runs only when they ask for it.
    ///
    /// Returns the layer on success so the caller can frame the map on it.
    @discardableResult
    func addFromAttachment(data: Data, filename: String,
                           senderCallsign: String) -> MapOverlayLayer? {
        do {
            let layer = try MapOverlayAttachment.layer(
                from: data, named: filename, senderCallsign: senderCallsign,
                colorName: MapOverlayLayer.color(forIndex: layers.count))
            layers.removeAll { $0.id == layer.id }
            layers.append(layer)
            persist(layer)
            lastError = nil
            return layer
        } catch let error as MapOverlayAttachment.ImportError {
            lastError = error.explanation
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Editing

    /// Adds a point the operator placed.
    ///
    /// Goes to the scratch layer, created on first use. Kept separate from
    /// imported layers on purpose: silently editing an agency's boundary file
    /// and writing it back would be worse than refusing to.
    @discardableResult
    func addPoint(at coordinate: CLLocationCoordinate2D,
                  name: String,
                  attributes: [String: String] = [:]) -> MapOverlayFeature {
        var merged = attributes
        // Marks the feature as ours so a round-trip through export and import
        // comes back editable rather than frozen.
        merged["axterm_placed"] = "1"

        let feature = MapOverlayFeature(name: name, geometry: .point(coordinate),
                                        attributes: merged, isUserPlaced: true)
        appendToScratch(feature)
        return feature
    }

    /// Adds a line or area the operator drew.
    @discardableResult
    func addShape(_ geometry: ShapefileReader.Geometry,
                  name: String,
                  attributes: [String: String] = [:]) -> MapOverlayFeature {
        var merged = attributes
        merged["axterm_placed"] = "1"
        let feature = MapOverlayFeature(name: name, geometry: geometry,
                                        attributes: merged, isUserPlaced: true)
        appendToScratch(feature)
        return feature
    }

    private func appendToScratch(_ feature: MapOverlayFeature) {
        if let index = layers.firstIndex(where: { $0.id == Self.scratchLayerID }) {
            layers[index].features.append(feature)
            persist(layers[index])
        } else {
            let layer = MapOverlayLayer(
                id: Self.scratchLayerID, name: Self.scratchLayerName,
                features: [feature],
                colorName: MapOverlayLayer.color(forIndex: layers.count),
                isVisible: true, isEditable: true)
            layers.append(layer)
            persist(layer)
        }
    }

    /// Removes one feature. Only features the operator placed can be removed —
    /// an imported layer is what the agency sent, and editing it in place
    /// would leave no way to tell what was original.
    func removeFeature(_ feature: MapOverlayFeature, from layer: MapOverlayLayer) {
        guard let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
        guard feature.isUserPlaced else {
            lastError = "\(layer.name) came from a file, so its features cannot be edited. Remove the whole layer instead, or place your own marks in \(Self.scratchLayerName)."
            return
        }
        layers[index].features.removeAll { $0.id == feature.id }
        if layers[index].features.isEmpty {
            remove(layers[index])
        } else {
            persist(layers[index])
        }
    }

    func rename(_ feature: MapOverlayFeature, to name: String, in layer: MapOverlayLayer) {
        guard let layerIndex = layers.firstIndex(where: { $0.id == layer.id }),
              let index = layers[layerIndex].features.firstIndex(where: { $0.id == feature.id })
        else { return }
        layers[layerIndex].features[index].name = name
        persist(layers[layerIndex])
    }

    // MARK: - Layers

    func remove(_ layer: MapOverlayLayer) {
        layers.removeAll { $0.id == layer.id }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(layer.id))
        try? FileManager.default.removeItem(at: Self.sidecarURL(for: layer.id, in: directory))
    }

    func setVisible(_ visible: Bool, for layer: MapOverlayLayer) {
        guard let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
        layers[index].isVisible = visible
        Self.writeSidecar(for: layers[index], in: directory)
    }

    // MARK: - Export

    /// The layer as GeoJSON, ready to save or attach.
    func exportGeoJSON(_ layer: MapOverlayLayer, pretty: Bool = true) throws -> Data {
        try GeoJSONWriter.data(for: layer, pretty: pretty)
    }

    /// The layer as a zipped ESRI shapefile, for handing to somebody running
    /// GIS software that will not read GeoJSON.
    func exportShapefile(_ layer: MapOverlayLayer) throws -> Data {
        try ShapefileWriter.zippedShapefile(layer: layer)
    }
}
