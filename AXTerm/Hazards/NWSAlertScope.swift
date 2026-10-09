import Foundation

/// Where the NWS layer fetches for (operator, 2026-10-09: "fetch by an
/// area, point, etc."). The station's point is what the "Inside" line needs;
/// a spotter also wants every warning nearby, or a county or a state.
nonisolated enum NWSAlertScope: Equatable, Sendable {
    /// Alerts at the station's position.
    case here
    /// Alerts whose shape comes within this many miles of the station. The
    /// API has no radius, so the states the circle could touch are asked
    /// for and what is too far is dropped (`keeping`).
    case within(miles: Double)
    /// Two-letter state or territory codes, e.g. CO.
    case states([String])
    /// NWS zone or county codes, e.g. COZ039 or COC005.
    case zones([String])
    /// Census county codes, e.g. 08005. Fetched as their states, so an
    /// alert issued by forecast zone is not missed, and kept when it names
    /// one of these counties (every alert lists its counties).
    case counties([String])

    // MARK: - Stored as text

    /// Where the choice is kept, beside the layer's own switch.
    static let storageKey = "stations.nwsAlertScope"

    /// "here", "within:50", "states:CO,WY", "zones:COZ039,COC005". Anything
    /// unreadable is the default, the station's point.
    init(stored: String) {
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first {
        case "within":
            guard parts.count == 2, let miles = Double(parts[1]), miles > 0 else { self = .here; return }
            self = .within(miles: miles)
        case "states":
            let codes = Self.codes(parts.count == 2 ? parts[1] : "")
            self = codes.isEmpty ? .here : .states(codes)
        case "counties":
            let codes = Self.codes(parts.count == 2 ? parts[1] : "").filter { $0.count == 5 && $0.allSatisfy(\.isNumber) }
            self = codes.isEmpty ? .here : .counties(codes)
        case "zones":
            let codes = Self.codes(parts.count == 2 ? parts[1] : "")
            self = codes.isEmpty ? .here : .zones(codes)
        default:
            self = .here
        }
    }

    var stored: String {
        switch self {
        case .here: return "here"
        case .within(let miles):
            return miles == miles.rounded() ? "within:\(Int(miles))" : "within:\(miles)"
        case .states(let codes): return "states:" + Self.codes(codes.joined(separator: ",")).joined(separator: ",")
        case .zones(let codes): return "zones:" + Self.codes(codes.joined(separator: ",")).joined(separator: ",")
        case .counties(let codes): return "counties:" + codes.joined(separator: ",")
        }
    }

    /// Codes as the API wants them: trimmed, upper case, no blanks.
    static func codes(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
    }

    /// What the area control shows for this choice.
    var summary: String {
        switch self {
        case .here: return "Where I am"
        case .within(let miles):
            return "Within \(miles == miles.rounded() ? String(Int(miles)) : String(miles)) mi"
        case .states(let codes): return codes.joined(separator: ", ")
        case .zones(let codes): return "Zones " + codes.joined(separator: ", ")
        case .counties(let codes): return "\(codes.count) count\(codes.count == 1 ? "y" : "ies")"
        }
    }

    /// The summary with county names where the table knows them, e.g.
    /// "Arapahoe, Douglas".
    func summary(counties table: CountyCenters?) -> String {
        switch self {
        case .states(let codes) where codes.count <= 2:
            // One or two in full ("Florida"); more stay as codes to fit.
            return codes.map { USStates.name($0) ?? $0 }.joined(separator: ", ")
        case .counties(let codes):
            guard let table else { return summary }
            return codes.map { table.county($0)?.shortName ?? $0 }.joined(separator: ", ")
        default:
            return summary
        }
    }

    /// The radii the area control offers.
    static let offeredRadii = [10, 25, 50, 100, 200]

    var needsPosition: Bool {
        switch self {
        case .here, .within: return true
        case .states, .zones, .counties: return false
        }
    }

    // MARK: - Within a radius

    /// The states a circle around `point` could touch, by each state's
    /// bounding box padded a quarter degree. Generous on purpose: an extra
    /// state costs one wider fetch, a missing one hides a warning.
    static func states(near point: GreatCircle.Point, miles: Double) -> [String] {
        stateBoxes.compactMap { code, box in
            let lat = min(max(point.latitude, box.minLat - 0.25), box.maxLat + 0.25)
            let lon = min(max(point.longitude, box.minLon - 0.25), box.maxLon + 0.25)
            return distanceMiles(point, GreatCircle.Point(latitude: lat, longitude: lon)) <= miles ? code : nil
        }.sorted()
    }

    /// Miles from a point to a shape: zero inside it, else to its nearest
    /// edge. Flat-earth over the few hundred miles a radius covers.
    static func miles(from point: GreatCircle.Point, to geometry: HazardFeature.Geometry) -> Double {
        if HazardContainment.contains(geometry, point) { return 0 }
        switch geometry {
        case .point(let p):
            return distanceMiles(point, p)
        case .polygons(let polygons):
            var best = Double.infinity
            for ring in polygons.flatMap({ $0 }) where !ring.isEmpty {
                for index in ring.indices {
                    let a = ring[index], b = ring[(index + 1) % ring.count]
                    best = min(best, segmentMiles(point, a, b))
                }
            }
            return best
        }
    }

    /// What a fetch keeps: within a radius, what is known to come within
    /// it (an alert whose zones have not loaded is counted by `unplaced`
    /// instead); every other scope keeps what the API returned.
    func keeping(_ features: [HazardFeature], near point: GreatCircle.Point?) -> [HazardFeature] {
        if case .counties(let chosen) = self {
            let wanted = Set(chosen)
            return features.filter { feature in
                CountyCenters.sameCodes(of: feature).compactMap(CountyCenters.geoid(fromSAME:))
                    .contains(where: wanted.contains)
            }
        }
        guard case .within(let radius) = self, let point else { return features }
        return features.filter { feature in
            guard let geometry = feature.geometry else { return false }
            return Self.miles(from: point, to: geometry) <= radius
        }
    }

    /// Alerts a radius cannot judge yet because their zones' outlines have
    /// not loaded; counted apart rather than as within it. Other scopes
    /// list them, so none are apart.
    func unplaced(_ features: [HazardFeature]) -> Int {
        guard case .within = self else { return 0 }
        return features.filter { $0.geometry == nil }.count
    }

    /// Why typed codes were not taken.
    enum EntryProblem: Error, Equatable {
        case empty
        /// A zone or county code typed under States.
        case looksLikeZones(String)
        /// A state code typed under Zones.
        case looksLikeStates(String)
        case unknown([String])

        var message: String {
            switch self {
            case .empty: return "Type at least one code."
            case .looksLikeZones(let code): return "\(code) is a zone or county code. Choose Zones to use it."
            case .looksLikeStates(let code): return "\(code) is a state code. Choose States to use it."
            case .unknown(let codes): return "Not a code the NWS uses: " + codes.joined(separator: ", ")
            }
        }
    }

    /// Typed codes, checked before anything is stored or fetched. Live on
    /// Station C, "COC007" under States was asked for as a state and the NWS
    /// rejected it (2026-10-09).
    static func entry(_ text: String, asStates: Bool) -> Result<NWSAlertScope, EntryProblem> {
        let list = codes(text)
        guard !list.isEmpty else { return .failure(.empty) }
        if asStates {
            if let zone = list.first(where: isZoneCode) { return .failure(.looksLikeZones(zone)) }
            let unknown = list.filter { !isStateCode($0) }
            return unknown.isEmpty ? .success(.states(list)) : .failure(.unknown(unknown))
        }
        if let state = list.first(where: isStateCode) { return .failure(.looksLikeStates(state)) }
        let unknown = list.filter { !isZoneCode($0) }
        return unknown.isEmpty ? .success(.zones(list)) : .failure(.unknown(unknown))
    }

    /// The states, DC, Puerto Rico and the other territories the NWS covers.
    static func isStateCode(_ code: String) -> Bool {
        stateBoxes[code] != nil || ["AS", "GU", "MP", "VI"].contains(code)
    }

    /// An NWS zone or county code: two letters, Z or C, three digits.
    static func isZoneCode(_ code: String) -> Bool {
        code.range(of: "^[A-Z]{2}[CZ][0-9]{3}$", options: .regularExpression) != nil
    }

    // MARK: - Geometry

    private static let milesPerDegree = 69.17

    private static func distanceMiles(_ a: GreatCircle.Point, _ b: GreatCircle.Point) -> Double {
        let scale = cos((a.latitude + b.latitude) / 2 * .pi / 180)
        let dx = (b.longitude - a.longitude) * scale, dy = b.latitude - a.latitude
        return (dx * dx + dy * dy).squareRoot() * milesPerDegree
    }

    private static func segmentMiles(_ p: GreatCircle.Point, _ a: GreatCircle.Point, _ b: GreatCircle.Point) -> Double {
        let scale = cos(p.latitude * .pi / 180)
        let ax = (a.longitude - p.longitude) * scale, ay = a.latitude - p.latitude
        let bx = (b.longitude - p.longitude) * scale, by = b.latitude - p.latitude
        let dx = bx - ax, dy = by - ay
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / length))
        let x = ax + t * dx, y = ay + t * dy
        return (x * x + y * y).squareRoot() * milesPerDegree
    }

    struct Box { let minLat, maxLat, minLon, maxLon: Double }

    /// Approximate bounding boxes of the states, DC and Puerto Rico. Only
    /// used to choose which states to ask for; the distance filter does the
    /// rest. Alaska's Aleutians past 180° are left out.
    static let stateBoxes: [String: Box] = [
        "AL": Box(minLat: 30.14, maxLat: 35.01, minLon: -88.47, maxLon: -84.89),
        "AK": Box(minLat: 51.20, maxLat: 71.40, minLon: -179.15, maxLon: -129.98),
        "AZ": Box(minLat: 31.33, maxLat: 37.00, minLon: -114.82, maxLon: -109.05),
        "AR": Box(minLat: 33.00, maxLat: 36.50, minLon: -94.62, maxLon: -89.64),
        "CA": Box(minLat: 32.53, maxLat: 42.01, minLon: -124.48, maxLon: -114.13),
        "CO": Box(minLat: 36.99, maxLat: 41.00, minLon: -109.06, maxLon: -102.04),
        "CT": Box(minLat: 40.98, maxLat: 42.05, minLon: -73.73, maxLon: -71.79),
        "DE": Box(minLat: 38.45, maxLat: 39.84, minLon: -75.79, maxLon: -75.05),
        "DC": Box(minLat: 38.79, maxLat: 38.99, minLon: -77.12, maxLon: -76.91),
        "FL": Box(minLat: 24.40, maxLat: 31.00, minLon: -87.63, maxLon: -80.03),
        "GA": Box(minLat: 30.36, maxLat: 35.00, minLon: -85.61, maxLon: -80.84),
        "HI": Box(minLat: 18.91, maxLat: 22.24, minLon: -160.25, maxLon: -154.81),
        "ID": Box(minLat: 41.99, maxLat: 49.00, minLon: -117.24, maxLon: -111.04),
        "IL": Box(minLat: 36.97, maxLat: 42.51, minLon: -91.51, maxLon: -87.49),
        "IN": Box(minLat: 37.77, maxLat: 41.76, minLon: -88.10, maxLon: -84.78),
        "IA": Box(minLat: 40.38, maxLat: 43.50, minLon: -96.64, maxLon: -90.14),
        "KS": Box(minLat: 36.99, maxLat: 40.00, minLon: -102.05, maxLon: -94.59),
        "KY": Box(minLat: 36.50, maxLat: 39.15, minLon: -89.57, maxLon: -81.96),
        "LA": Box(minLat: 28.93, maxLat: 33.02, minLon: -94.04, maxLon: -88.82),
        "ME": Box(minLat: 42.98, maxLat: 47.46, minLon: -71.08, maxLon: -66.95),
        "MD": Box(minLat: 37.91, maxLat: 39.72, minLon: -79.49, maxLon: -75.05),
        "MA": Box(minLat: 41.24, maxLat: 42.89, minLon: -73.51, maxLon: -69.93),
        "MI": Box(minLat: 41.70, maxLat: 48.31, minLon: -90.42, maxLon: -82.41),
        "MN": Box(minLat: 43.50, maxLat: 49.38, minLon: -97.24, maxLon: -89.49),
        "MS": Box(minLat: 30.17, maxLat: 35.00, minLon: -91.66, maxLon: -88.10),
        "MO": Box(minLat: 36.00, maxLat: 40.61, minLon: -95.77, maxLon: -89.10),
        "MT": Box(minLat: 44.36, maxLat: 49.00, minLon: -116.05, maxLon: -104.04),
        "NE": Box(minLat: 40.00, maxLat: 43.00, minLon: -104.05, maxLon: -95.31),
        "NV": Box(minLat: 35.00, maxLat: 42.00, minLon: -120.01, maxLon: -114.04),
        "NH": Box(minLat: 42.70, maxLat: 45.31, minLon: -72.56, maxLon: -70.61),
        "NJ": Box(minLat: 38.93, maxLat: 41.36, minLon: -75.56, maxLon: -73.89),
        "NM": Box(minLat: 31.33, maxLat: 37.00, minLon: -109.05, maxLon: -103.00),
        "NY": Box(minLat: 40.50, maxLat: 45.02, minLon: -79.76, maxLon: -71.86),
        "NC": Box(minLat: 33.84, maxLat: 36.59, minLon: -84.32, maxLon: -75.46),
        "ND": Box(minLat: 45.94, maxLat: 49.00, minLon: -104.05, maxLon: -96.55),
        "OH": Box(minLat: 38.40, maxLat: 41.98, minLon: -84.82, maxLon: -80.52),
        "OK": Box(minLat: 33.62, maxLat: 37.00, minLon: -103.00, maxLon: -94.43),
        "OR": Box(minLat: 41.99, maxLat: 46.29, minLon: -124.57, maxLon: -116.46),
        "PA": Box(minLat: 39.72, maxLat: 42.27, minLon: -80.52, maxLon: -74.69),
        "RI": Box(minLat: 41.15, maxLat: 42.02, minLon: -71.86, maxLon: -71.12),
        "SC": Box(minLat: 32.03, maxLat: 35.22, minLon: -83.35, maxLon: -78.54),
        "SD": Box(minLat: 42.48, maxLat: 45.95, minLon: -104.06, maxLon: -96.44),
        "TN": Box(minLat: 34.98, maxLat: 36.68, minLon: -90.31, maxLon: -81.65),
        "TX": Box(minLat: 25.84, maxLat: 36.50, minLon: -106.65, maxLon: -93.51),
        "UT": Box(minLat: 37.00, maxLat: 42.00, minLon: -114.05, maxLon: -109.04),
        "VT": Box(minLat: 42.73, maxLat: 45.02, minLon: -73.44, maxLon: -71.46),
        "VA": Box(minLat: 36.54, maxLat: 39.47, minLon: -83.68, maxLon: -75.24),
        "WA": Box(minLat: 45.54, maxLat: 49.00, minLon: -124.85, maxLon: -116.92),
        "WV": Box(minLat: 37.20, maxLat: 40.64, minLon: -82.64, maxLon: -77.72),
        "WI": Box(minLat: 42.49, maxLat: 47.31, minLon: -92.89, maxLon: -86.25),
        "WY": Box(minLat: 40.99, maxLat: 45.01, minLon: -111.06, maxLon: -104.05),
        "PR": Box(minLat: 17.88, maxLat: 18.52, minLon: -67.95, maxLon: -65.22),
    ]
}

extension NWSAlertFeed {

    /// The request for a scope, or nil when the scope needs a position and
    /// there is none.
    static func alertsRequest(_ scope: NWSAlertScope, at point: GreatCircle.Point?) -> URLRequest? {
        switch scope {
        case .here:
            return point.map(alertsRequest(near:))
        case .within(let miles):
            guard let point else { return nil }
            let states = NWSAlertScope.states(near: point, miles: miles)
            guard !states.isEmpty else { return alertsRequest(near: point) }
            return zoneRequest(URL(string: "https://api.weather.gov/alerts/active?area=" + states.joined(separator: ","))!)
        case .states(let codes):
            return zoneRequest(URL(string: "https://api.weather.gov/alerts/active?area=" + codes.joined(separator: ","))!)
        case .zones(let codes):
            return zoneRequest(URL(string: "https://api.weather.gov/alerts/active?zone=" + codes.joined(separator: ","))!)
        case .counties:
            return alertsRequest(scope, at: point, counties: CountyCenters.bundled)
        }
    }

    /// As above, with the county table that turns chosen counties into the
    /// states to ask for.
    static func alertsRequest(_ scope: NWSAlertScope, at point: GreatCircle.Point?,
                              counties: CountyCenters?) -> URLRequest? {
        guard case .counties(let codes) = scope else { return alertsRequest(scope, at: point) }
        var states: [String] = []
        for code in codes {
            guard let state = counties?.county(code)?.state, !states.contains(state) else { continue }
            states.append(state)
        }
        guard !states.isEmpty else { return nil }
        return zoneRequest(URL(string: "https://api.weather.gov/alerts/active?area=" + states.joined(separator: ","))!)
    }
}

/// The States and Counties checklists: what ticking does and what each
/// list offers, so neither asks for a typed code.
extension NWSAlertScope {
    /// How many nearby counties the list offers before a search.
    static let nearbyCountyCount = 25

    func toggling(state code: String) -> NWSAlertScope {
        var list: [String] = []
        if case .states(let chosen) = self { list = chosen }
        if let index = list.firstIndex(of: code) { list.remove(at: index) } else { list.append(code) }
        return list.isEmpty ? .here : .states(list)
    }

    func toggling(county geoid: String) -> NWSAlertScope {
        var list: [String] = []
        if case .counties(let chosen) = self { list = chosen }
        if let index = list.firstIndex(of: geoid) { list.remove(at: index) } else { list.append(geoid) }
        return list.isEmpty ? .here : .counties(list)
    }

    func isChosen(state code: String) -> Bool {
        if case .states(let chosen) = self { return chosen.contains(code) }
        return false
    }

    func isChosen(county geoid: String) -> Bool {
        if case .counties(let chosen) = self { return chosen.contains(geoid) }
        return false
    }

    /// Ticked counties first, wherever they are, then the nearest ones, or
    /// the matches when there is a search.
    func countyChoices(table: CountyCenters?, near point: GreatCircle.Point?, search: String) -> [CountyCenters.Entry] {
        guard let table else { return [] }
        var chosen: [String] = []
        if case .counties(let list) = self { chosen = list }
        let ticked = chosen.compactMap { table.entry($0, from: point) }
        let query = search.trimmingCharacters(in: .whitespaces)
        let rest = query.isEmpty
            ? (point.map { table.nearest(to: $0, limit: Self.nearbyCountyCount) } ?? [])
            : table.search(query, near: point)
        return ticked + rest.filter { !chosen.contains($0.geoid) }
    }

    /// The station's state and the ticked ones first, then the rest by name.
    func stateChoices(home: String?) -> [USStates.State] {
        var leading: [String] = home.map { [$0] } ?? []
        if case .states(let chosen) = self {
            leading += chosen.filter { !leading.contains($0) }
        }
        let first = leading.compactMap { code in USStates.name(code).map { USStates.State(code: code, name: $0) } }
        return first + USStates.all.filter { !leading.contains($0.code) }
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// The NWS layer's area choice under its switch (`NWSAlertScope`): where the
/// station is, within a distance of it, or ticked states or counties.
/// Nothing is typed: States and Counties open a checklist, and switching to
/// either starts with the station's own state or county ticked.
struct NWSAlertAreaControl: View {
    @AppStorage(NWSAlertScope.storageKey) private var stored = "here"
    @State private var checklist: NWSAreaChecklist.Kind?

    private enum Kind: String, CaseIterable, Identifiable {
        case here = "Where I am", within = "Within", states = "States", counties = "Counties"
        /// Only while an older typed zone list is stored.
        case zones = "Zones"
        var id: String { rawValue }
    }

    private var scope: NWSAlertScope { NWSAlertScope(stored: stored) }

    private var storedKind: Kind {
        switch scope {
        case .here: return .here
        case .within: return .within
        case .states: return .states
        case .counties: return .counties
        case .zones: return .zones
        }
    }

    private var kind: Binding<Kind> {
        Binding(get: { storedKind }, set: { kind in
            guard kind != storedKind else { return }
            switch kind {
            case .here: stored = NWSAlertScope.here.stored
            case .within: stored = NWSAlertScope.within(miles: 50).stored
            case .states:
                stored = NWSAreaChecklist.starting(.states).stored
                checklist = .states
            case .counties:
                stored = NWSAreaChecklist.starting(.counties).stored
                checklist = .counties
            case .zones: break
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Alert area", selection: kind) {
                ForEach(Kind.allCases.filter { $0 != .zones || storedKind == .zones }) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Where the NWS layer fetches for. Where I am: alerts at this station's position. "
                  + "Within: every alert whose shape comes within that distance. States and Counties: "
                  + "everything the NWS has for the ones you tick.")
            switch storedKind {
            case .within:
                Picker("Distance", selection: Binding(
                    get: { if case .within(let miles) = scope { return Int(miles) } else { return 50 } },
                    set: { stored = NWSAlertScope.within(miles: Double($0)).stored })) {
                    ForEach(NWSAlertScope.offeredRadii, id: \.self) { Text("\($0) mi").tag($0) }
                }
                .pickerStyle(.menu)
            case .states, .counties:
                HStack {
                    Text(scope.summary(counties: CountyCenters.bundled))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Choose…") { checklist = storedKind == .states ? .states : .counties }
                }
            case .zones:
                Text(scope.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .here:
                EmptyView()
            }
        }
        .sheet(item: $checklist) { kind in
            NWSAreaChecklist(kind: kind)
        }
    }
}

/// Tick the states or counties the NWS layer fetches for. Counties lead
/// with the nearest ones, so most stations never need the search.
struct NWSAreaChecklist: View {
    enum Kind: String, Identifiable {
        case states, counties
        var id: String { rawValue }
    }

    let kind: Kind
    @AppStorage(NWSAlertScope.storageKey) private var stored = "here"
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var scope: NWSAlertScope { NWSAlertScope(stored: stored) }

    /// Where the station is, from its grid or set position.
    static var stationPoint: GreatCircle.Point? {
        StationPositionResolver.ownStation(defaults: AppEnvironment.defaults, deviceLocation: nil)?.point
    }

    /// The area a switch to States or Counties starts from: what was ticked
    /// before, else the station's own state or county.
    static func starting(_ kind: Kind) -> NWSAlertScope {
        let current = NWSAlertScope(stored: AppEnvironment.defaults.string(forKey: NWSAlertScope.storageKey) ?? "")
        let table = CountyCenters.bundled
        let point = stationPoint
        switch kind {
        case .states:
            if case .states = current { return current }
            guard let point, let home = table?.state(at: point) else { return .here }
            return .states([home])
        case .counties:
            if case .counties = current { return current }
            guard let point, let home = table?.nearest(to: point, limit: 1).first else { return .here }
            return .counties([home.geoid])
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // A plain field: only the window may install a search
                // field (ToolbarUniquenessTests).
                TextField(kind == .states ? "Filter states" : "Find a county by name", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                switch kind {
                case .states: statesList
                case .counties: countiesList
                }
            }
            .navigationTitle(kind == .states ? "Alert States" : "Alert Counties")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
        #else
        .presentationDragIndicator(.visible)
        #endif
    }

    @ViewBuilder
    private var statesList: some View {
        let home = Self.stationPoint.flatMap { CountyCenters.bundled?.state(at: $0) }
        let all = scope.stateChoices(home: home).filter(matchesSearch)
        let chosen = all.filter { scope.isChosen(state: $0.code) }
        if !chosen.isEmpty {
            Section("Chosen") {
                ForEach(chosen) { state in stateRow(state, home: home) }
            }
        }
        Section {
            ForEach(all.filter { !scope.isChosen(state: $0.code) }) { state in stateRow(state, home: home) }
        } header: {
            Text("States")
        } footer: {
            Text("Every alert the NWS has for the states you tick.")
        }
    }

    private func stateRow(_ state: USStates.State, home: String?) -> some View {
        ChecklistRow(title: state.name, detail: state.code == home ? "Your station" : nil,
                     chosen: scope.isChosen(state: state.code)) {
            withAnimation { stored = scope.toggling(state: state.code).stored }
        }
    }

    @ViewBuilder
    private var countiesList: some View {
        let entries = scope.countyChoices(table: CountyCenters.bundled, near: Self.stationPoint, search: search)
        let chosen = entries.filter { scope.isChosen(county: $0.geoid) }
        let rest = entries.filter { !scope.isChosen(county: $0.geoid) }
        if !chosen.isEmpty {
            Section("Chosen") {
                ForEach(chosen, id: \.geoid) { entry in countyRow(entry) }
            }
        }
        Section {
            if rest.isEmpty {
                Text(Self.stationPoint == nil && search.isEmpty
                     ? "Search for a county by name. Set a grid square to list the nearest ones."
                     : "No other county by that name.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rest, id: \.geoid) { entry in countyRow(entry) }
        } header: {
            Text(search.trimmingCharacters(in: .whitespaces).isEmpty ? "Nearby" : "Matches")
        } footer: {
            Text("The NWS is asked for these counties' states, and the alerts that name one of them are kept, "
                 + "including ones issued by forecast zone.")
        }
    }

    private func countyRow(_ entry: CountyCenters.Entry) -> some View {
        ChecklistRow(title: "\(entry.county.name), \(entry.county.state)",
                     detail: entry.distanceText.isEmpty ? nil : entry.distanceText,
                     chosen: scope.isChosen(county: entry.geoid)) {
            withAnimation { stored = scope.toggling(county: entry.geoid).stored }
        }
    }

    private func matchesSearch(_ state: USStates.State) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || state.name.localizedCaseInsensitiveContains(query) || state.code == query.uppercased()
    }
}
/// A row that ticks on a tap: a checkmark, the way a list of choices
/// reads on iPhone, iPad and Mac alike.
private struct ChecklistRow: View {
    let title: String
    let detail: String?
    let chosen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
#endif
