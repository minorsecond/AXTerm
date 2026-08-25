import Foundation
import CoreLocation
import MapKit

/// What the next tap on the map means.
nonisolated enum MapDrawingMode: String, CaseIterable, Identifiable, Sendable {
    /// Taps select stations, as usual.
    case off
    /// Each tap drops a labelled mark.
    case point
    /// Taps add vertices to a line.
    case line
    /// Taps add vertices to an area.
    case area
    /// Taps bound a region to fetch map tiles and terrain for.
    ///
    /// A separate mode rather than a use of `.area`, because it produces no
    /// saved feature and asks for no name — the shape is a question about
    /// what to download, not a thing to keep.
    case download

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Select"
        case .point: "Mark"
        case .line: "Line"
        case .area: "Area"
        case .download: "Download"
        }
    }

    var systemImage: String {
        switch self {
        case .off: "hand.point.up.left"
        case .point: "mappin"
        case .line: "scribble"
        case .area: "pentagon"
        case .download: "square.and.arrow.down.on.square"
        }
    }

    /// Whether this mode accumulates vertices before producing anything.
    var isMultiPoint: Bool { self == .line || self == .area || self == .download }

    var help: String {
        switch self {
        case .off:
            "Tapping the map selects a station."
        case .point:
            "Tap the map to drop a mark and name it. Marks are saved on this device and can be exported or sent."
        case .line:
            "Tap to add each point of a line — a route, a path, a boundary that is not closed. Needs at least two points."
        case .area:
            "Tap to add each corner of an area — a zone, a search sector, a coverage estimate. Needs at least three corners; the shape closes itself."
        case .download:
            "Tap the corners of the area you want available offline, then finish — the map tiles and the elevation data for exactly that box get downloaded. Nothing is saved as a feature; the shape is only a way of saying where."
        }
    }
}

/// Vertices collected so far, and the rules for turning them into geometry.
///
/// Separate from the map view so the rules can be tested without tapping
/// anything. The rules matter more than they look: a two-point "area" and a
/// one-point "line" are both degenerate geometry that every downstream
/// consumer — the shapefile writer, GeoJSON, MapKit's renderer — handles
/// differently and none handle well. Refusing them here is cheaper than
/// discovering them in a file somebody else opened.
nonisolated struct MapDrawingSession: Equatable, Sendable {

    private(set) var mode: MapDrawingMode
    private(set) var vertices: [CLLocationCoordinate2D]

    init(mode: MapDrawingMode = .off, vertices: [CLLocationCoordinate2D] = []) {
        self.mode = mode
        self.vertices = vertices
    }

    /// Written out because `CLLocationCoordinate2D` is not `Equatable` — it
    /// is a C struct Core Location never conformed.
    static func == (lhs: MapDrawingSession, rhs: MapDrawingSession) -> Bool {
        lhs.mode == rhs.mode
            && lhs.vertices.count == rhs.vertices.count
            && zip(lhs.vertices, rhs.vertices).allSatisfy {
                $0.latitude == $1.latitude && $0.longitude == $1.longitude
            }
    }

    /// Minimum vertices before the shape can be completed.
    static func minimumVertices(for mode: MapDrawingMode) -> Int {
        switch mode {
        case .off: 0
        case .point: 1
        case .line: 2
        case .area: 3
        // Two opposite corners are enough to describe a box, and asking for
        // a third corner to define a rectangle is busywork.
        case .download: 2
        }
    }

    var isDrawing: Bool { mode != .off }
    var canComplete: Bool { vertices.count >= Self.minimumVertices(for: mode) }
    var canUndo: Bool { !vertices.isEmpty }

    /// What the operator still needs to do, stated rather than left to a
    /// disabled button they cannot explain.
    var progressText: String? {
        guard mode.isMultiPoint else { return nil }
        let needed = Self.minimumVertices(for: mode)
        if vertices.count < needed {
            let remaining = needed - vertices.count
            return "\(vertices.count) of \(needed) — tap \(remaining) more"
        }
        return "\(vertices.count) points — tap Done to finish"
    }

    mutating func begin(_ mode: MapDrawingMode) {
        self.mode = mode
        vertices = []
    }

    mutating func cancel() {
        mode = .off
        vertices = []
    }

    /// Adds a vertex. Returns true when the shape is immediately complete —
    /// which is only ever a single point, since lines and areas are finished
    /// deliberately.
    @discardableResult
    mutating func addVertex(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard isDrawing else { return false }
        vertices.append(coordinate)
        return mode == .point
    }

    mutating func undoVertex() {
        guard !vertices.isEmpty else { return }
        vertices.removeLast()
    }

    /// The finished geometry, or nil when there are not enough vertices.
    ///
    /// An area is **not** closed here: the ring is stored open and closed on
    /// write, which is what both GeoJSON and the shapefile writer expect. A
    /// ring closed twice has a duplicated point that some readers report as a
    /// degenerate edge.
    func geometry() -> ShapefileReader.Geometry? {
        guard canComplete else { return nil }
        switch mode {
        case .off:
            return nil
        case .point:
            guard let first = vertices.first else { return nil }
            return .point(first)
        case .line:
            return .polyline([vertices])
        case .area:
            return .polygon([vertices])
        case .download:
            // The corners describe a box, so the geometry is that box rather
            // than the path tapped out. Downloading tiles for a polygon's
            // outline instead of its extent would miss the middle.
            guard let bounds = boundingBox() else { return nil }
            return .polygon([bounds])
        }
    }

    /// The rectangle enclosing every vertex, closed.
    ///
    /// Tiles are square and a download is a rectangle, so any drawn shape
    /// becomes its own bounding box. Said plainly here rather than left
    /// implicit, because an operator drawing a narrow diagonal corridor gets
    /// the whole box and should not be surprised by the size.
    func boundingBox() -> [CLLocationCoordinate2D]? {
        guard let first = vertices.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for vertex in vertices.dropFirst() {
            minLat = min(minLat, vertex.latitude)
            maxLat = max(maxLat, vertex.latitude)
            minLon = min(minLon, vertex.longitude)
            maxLon = max(maxLon, vertex.longitude)
        }
        guard minLat != maxLat, minLon != maxLon else { return nil }
        return [
            CLLocationCoordinate2D(latitude: maxLat, longitude: minLon),
            CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon),
            CLLocationCoordinate2D(latitude: minLat, longitude: maxLon),
            CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
            CLLocationCoordinate2D(latitude: maxLat, longitude: minLon),
        ]
    }

    /// The drawn extent as a map region, for the download to act on.
    func region() -> MKCoordinateRegion? {
        guard let first = vertices.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for vertex in vertices.dropFirst() {
            minLat = min(minLat, vertex.latitude)
            maxLat = max(maxLat, vertex.latitude)
            minLon = min(minLon, vertex.longitude)
            maxLon = max(maxLon, vertex.longitude)
        }
        guard minLat != maxLat, minLon != maxLon else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: maxLat - minLat,
                                   longitudeDelta: maxLon - minLon))
    }

    /// Vertices for the in-progress preview.
    ///
    /// An area shows its closing edge while being drawn so the operator can
    /// see the shape they are making, not the open path they have tapped.
    func previewVertices() -> [CLLocationCoordinate2D] {
        // A download box previews as the box itself, so what is about to be
        // fetched is what is on screen.
        if mode == .download, vertices.count >= 2, let box = boundingBox() {
            return box
        }
        guard mode == .area, vertices.count >= 3, let first = vertices.first else {
            return vertices
        }
        return vertices + [first]
    }
}

// MARK: - Labels

/// Where a feature's label goes.
///
/// Every feature gets one — "label them all" is not decoration here: a zone
/// with no name on it is indistinguishable from the zone beside it, and the
/// whole reason for drawing boundaries during an activation is to say which
/// is which.
nonisolated enum MapFeatureLabel {

    /// A representative point to hang the label on.
    ///
    /// For an area this is the **area-weighted centroid**, not the centre of
    /// the bounding box. They differ a lot for a real boundary — an L-shaped
    /// county puts its bounding-box centre outside itself, which would float
    /// the label over the neighbouring county.
    static func anchor(for geometry: ShapefileReader.Geometry) -> CLLocationCoordinate2D? {
        switch geometry {
        case .point(let coordinate):
            return coordinate

        case .polyline(let parts):
            // Midpoint of the longest part, by vertex count: a label at the
            // start of a route sits on top of whatever is at the start.
            guard let longest = parts.max(by: { $0.count < $1.count }), !longest.isEmpty else {
                return nil
            }
            return longest[longest.count / 2]

        case .polygon(let rings):
            guard let outer = rings.first, outer.count >= 3 else {
                return rings.first?.first
            }
            return centroid(of: outer) ?? boundingCentre(of: outer)
        }
    }

    /// Area-weighted centroid of a ring, by the shoelace formula.
    ///
    /// Returns nil for a degenerate ring — three collinear points enclose no
    /// area, and the formula divides by it.
    static func centroid(of ring: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard ring.count >= 3 else { return nil }
        var twiceArea = 0.0
        var x = 0.0
        var y = 0.0

        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            let cross = a.longitude * b.latitude - b.longitude * a.latitude
            twiceArea += cross
            x += (a.longitude + b.longitude) * cross
            y += (a.latitude + b.latitude) * cross
        }

        guard abs(twiceArea) > 1e-12 else { return nil }
        let factor = 1 / (3 * twiceArea)
        return CLLocationCoordinate2D(latitude: y * factor, longitude: x * factor)
    }

    static func boundingCentre(of ring: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard !ring.isEmpty else { return nil }
        let lats = ring.map(\.latitude)
        let lons = ring.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        return CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                      longitude: (minLon + maxLon) / 2)
    }
}
