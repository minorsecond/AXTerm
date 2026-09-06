import Foundation

/// Turns the stations this receiver has heard into something plottable.
///
/// Heard stations arrive as a callsign and a timestamp — no position at
/// all. A position comes from one of two places, both of which may be
/// absent: the Winlink RMS cache (gateways, grid square from the CMS) or
/// the callsign directory (anyone, if it has been looked up).
///
/// So the honest output is **two lists**: what can be placed, and what
/// cannot. A station heard 400 times that nobody can locate is not a
/// failure to hide; it is the most interesting row in the table.
nonisolated enum HeardStationMap {

    /// How much a position can be trusted, and about *what*.
    ///
    /// Precision and accuracy are different axes and conflating them is
    /// how a map lies confidently. A licence address is exact to seven
    /// decimals and describes *the licensee's mailing address*; a grid
    /// square is coarse and describes *the thing that registered it*.
    /// The precise one is not automatically the better one.
    enum PositionConfidence: Int, Comparable, Sendable {
        /// Inferred from a *different* entity — a node alias placed at
        /// its operator's address. NET/ROM nodes usually live on a
        /// hilltop or a repeater site, not at the operator's house, so
        /// this is a lead, not a location.
        case inferredFromOperator
        /// Centre of a registered grid square: coarse, but it describes
        /// the station itself.
        case gridSquare
        /// An exact coordinate consistent with everything else known.
        case exact

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .exact: "exact"
            case .gridSquare: "grid square"
            case .inferredFromOperator: "operator's address"
            }
        }
    }

    /// One heard station with whatever is known about it.
    struct Entry: Equatable, Sendable, Identifiable {
        var callsign: String
        var heardCount: Int
        var lastHeard: Date?
        var lastVia: [String]

        /// Where the position came from, or nil if unplaced.
        var position: GreatCircle.Point?
        var positionSource: String?
        /// What the position actually describes — which is a different
        /// question from how precise it is.
        var confidence: PositionConfidence = .gridSquare
        var isExactPosition: Bool { confidence == .exact }
        var gridSquare: String?
        /// Licensee name, when a directory has been consulted.
        var name: String?
        var locality: String?
        /// A NET/ROM alias (`DRLNOD`) rather than a station callsign.
        var isNodeAlias: Bool = false
        /// The callsign behind a node alias, when the directory knows it —
        /// the licence the network's tactical name resolves to.
        var nodeCallsign: String?

        var id: String { callsign }
        var isPlaced: Bool { position != nil }
    }

    /// Heard within this long counts as active.
    static let activeWindow: TimeInterval = 3600
    /// Beyond this a station is drawn faded — heard once, hours ago.
    static let staleWindow: TimeInterval = 24 * 3600

    /// Builds entries for every heard station.
    ///
    /// - Parameters:
    ///   - stations: what the receiver has heard.
    ///   - directory: cached callsign records, keyed by **base** callsign.
    ///   - gatewayGrids: grid squares from the RMS cache, keyed by full
    ///     callsign including SSID — a gateway's position is known even
    ///     when its licensee has never been looked up.
    ///   - excluding: the operator's own callsign. A station hears its
    ///     own transmissions come back digipeated, so without this the
    ///     operator appears twice — once as the centre marker and again
    ///     as a heard station a few metres away.
    static func entries(stations: [Station],
                        directory: [String: CallsignRecord],
                        gatewayGrids: [String: String],
                        announcedGrids: [String: String] = [:],
                        excluding ownCallsign: String = "") -> [Entry] {
        let own = CallsignQuery.normalize(ownCallsign)
        return stations.filter {
            own.isEmpty || CallsignQuery.normalize($0.call) != own
        }.map { station in
            let call = station.call.uppercased()
            let base = CallsignQuery.normalize(call)
            let record = directory[base]
            let grid = gatewayGrids[call]

            // Precision and identity are different questions. A licence
            // address is exact but describes the *licensee*; an RMS grid
            // describes the *gateway* that registered it. So an exact
            // coordinate is used as a refinement only when it agrees
            // with the coarser claim — when it falls inside the square
            // the station itself registered. When they disagree, the
            // source that is about the right entity wins, and the
            // disagreement is reported rather than silently resolved.
            let exact = record.flatMap { candidate -> GreatCircle.Point? in
                guard let latitude = candidate.latitude,
                      let longitude = candidate.longitude else { return nil }
                return GreatCircle.Point(latitude: latitude, longitude: longitude)
            }

            if let exact, let grid, !gridContains(grid, exact) {
                // The two sources put this station in different places.
                return Entry(
                    callsign: call, heardCount: station.heardCount,
                    lastHeard: station.lastHeard, lastVia: station.lastVia,
                    position: Maidenhead.center(of: grid).map(GreatCircle.Point.init),
                    positionSource: "RMS directory grid square (disagrees with \(record?.source ?? "the licence address"), which is elsewhere)",
                    confidence: .gridSquare,
                    gridSquare: grid.uppercased(),
                    name: record?.name, locality: record?.locality)
            }
            if let exact, let record {
                return Entry(
                    callsign: call, heardCount: station.heardCount,
                    lastHeard: station.lastHeard, lastVia: station.lastVia,
                    position: exact,
                    positionSource: grid == nil
                        ? "\(record.source) licence address"
                        : "\(record.source) licence address, inside the registered grid \(grid!.uppercased())",
                    confidence: .exact,
                    gridSquare: (grid ?? record.gridSquare)?.uppercased(),
                    name: record.name, locality: record.locality)
            }
            if let grid, let center = Maidenhead.center(of: grid) {
                return Entry(
                    callsign: call, heardCount: station.heardCount,
                    lastHeard: station.lastHeard, lastVia: station.lastVia,
                    position: GreatCircle.Point(center),
                    positionSource: "RMS directory grid square",
                    confidence: .gridSquare,
                    gridSquare: grid.uppercased(),
                    name: record?.name, locality: record?.locality)
            }
            // The station's own beacon, when it carried a locator. This is
            // the placement most of the world gets — no directory covers
            // it, but the station said where it is, over the air. Below
            // the registries above (both are vetted claims about the same
            // station), above the licensee fallbacks below (which describe
            // the operator, not the station).
            if let announced = announcedGrids[call],
               let center = Maidenhead.center(of: announced) {
                return Entry(
                    callsign: call, heardCount: station.heardCount,
                    lastHeard: station.lastHeard, lastVia: station.lastVia,
                    position: GreatCircle.Point(center),
                    positionSource: "locator announced in its own beacon",
                    confidence: .gridSquare,
                    gridSquare: announced.uppercased(),
                    name: record?.name, locality: record?.locality)
            }
            if let record, let position = record.position {
                return Entry(
                    callsign: call, heardCount: station.heardCount,
                    lastHeard: station.lastHeard, lastVia: station.lastVia,
                    position: position,
                    positionSource: "\(record.source) grid square",
                    confidence: .gridSquare,
                    gridSquare: record.gridSquare?.uppercased(),
                    name: record.name, locality: record.locality)
            }
            return Entry(
                callsign: call, heardCount: station.heardCount,
                lastHeard: station.lastHeard, lastVia: station.lastVia,
                name: record?.name, locality: record?.locality)
        }
        // Most recently heard first; ties by callsign so the order is
        // stable between redraws.
        .sorted {
            ($0.lastHeard ?? .distantPast, $1.callsign) > ($1.lastHeard ?? .distantPast, $0.callsign)
        }
    }

    /// Whether an exact coordinate falls inside a grid square — the
    /// test for "these two sources agree".
    static func gridContains(_ grid: String, _ point: GreatCircle.Point) -> Bool {
        guard let centre = Maidenhead.center(of: grid) else { return false }
        // A 6-character subsquare is 5\u{2032} of longitude by 2.5\u{2032} of
        // latitude; 4-character squares are 2\u{00B0} by 1\u{00B0}. Half-extents,
        // with a little slack for rounding in either source.
        let characters = grid.trimmingCharacters(in: .whitespaces).count
        let latHalf = (characters >= 6 ? 1.0 / 24 : 1.0) / 2 * 1.05
        let lonHalf = (characters >= 6 ? 2.0 / 24 : 2.0) / 2 * 1.05
        return abs(point.latitude - centre.latitude) <= latHalf
            && abs(point.longitude - centre.longitude) <= lonHalf
    }

    /// Groups entries that resolve to the *same* position.
    ///
    /// Every SSID of one licensee resolves through the same directory
    /// record, so `K0NTS-1`, `-7`, `-10` and `-14` all land on one point
    /// — four markers stacked exactly on top of each other, which reads
    /// as one marker and hides three stations. One marker per position,
    /// labelled with what is actually there, is the honest rendering.
    static func clusters(_ entries: [Entry]) -> [[Entry]] {
        var order: [String] = []
        var groups: [String: [Entry]] = [:]
        for entry in entries {
            guard let position = entry.position else { continue }
            // Five decimals is about a metre — far finer than any source
            // here, so this groups co-located stations without merging
            // genuinely distinct ones.
            let key = String(format: "%.5f,%.5f", position.latitude, position.longitude)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.compactMap { groups[$0] }
    }

    /// Label for a cluster of stations at one point.
    static func clusterLabel(_ cluster: [Entry]) -> String {
        guard let first = cluster.first else { return "" }
        if cluster.count == 1 { return first.callsign }
        let bases = Set(cluster.map { CallsignQuery.normalize($0.callsign) })
        if bases.count == 1, let base = bases.first {
            return "\(base) \u{00D7}\(cluster.count)"
        }
        let principal = cluster.max {
            ($0.heardCount, $1.callsign) < ($1.heardCount, $0.callsign)
        } ?? first
        return "\(principal.callsign) +\(cluster.count - 1)"
    }

    /// How far apart to fan co-located stations, in metres.
    ///
    /// A six-character grid square is about 8 × 4.6 km, so every station
    /// in it resolves to the *same* centre point — identical to the
    /// metre. Stacked markers can never be separated by zooming, because
    /// they are genuinely at one coordinate.
    ///
    /// Spreading them by 500 m stays well inside the square the position
    /// came from, so the fan is not a fabrication: it says "somewhere in
    /// this square", which is exactly what a grid reference means. A
    /// station with an exact position is never offset.
    /// Grid-square positions share a box up to 8 km across, so a
    /// several-hundred-metre spread stays well inside what the position
    /// actually claims.
    static let gridFanRadiusMetres = 400.0
    /// Exact positions are a real point — usually one licensee's several
    /// SSIDs at one address. Spread them just enough to click.
    static let exactFanRadiusMetres = 40.0

    /// Positions for every placed entry, fanning co-located stations so
    /// each is individually visible and selectable.
    ///
    /// One source of truth for the map and the scope — computed twice
    /// they would disagree about where a marker is.
    static func fannedPositions(_ entries: [Entry]) -> [String: GreatCircle.Point] {
        var result = [String: GreatCircle.Point]()
        for cluster in clusters(entries) {
            guard let anchor = cluster.first?.position else { continue }
            if cluster.count == 1 {
                result[cluster[0].callsign] = anchor
                continue
            }
            let centre = clusterCentre(anchor)
            for entry in cluster {
                let radius = entry.isExactPosition
                    ? exactFanRadiusMetres : gridFanRadiusMetres
                let (metresNorth, metresEast) = fanOffset(
                    callsign: entry.callsign, radius: radius)
                let cosLat = max(0.01, cos(centre.latitude * .pi / 180))
                result[entry.callsign] = GreatCircle.Point(
                    latitude: centre.latitude + metresNorth / 111_320,
                    longitude: centre.longitude + metresEast / (111_320 * cosLat))
            }
        }
        return result
    }

    /// The one point a cluster fans around, whoever is in it.
    ///
    /// `clusters` groups on coordinates rounded to five decimals, so members
    /// agree to about a metre without being identical. Taking any member's
    /// raw position as the centre therefore moved the whole cluster whenever
    /// its membership changed. Re-deriving the grouping key instead — via the
    /// same formatting, so the two can never disagree — gives a centre that
    /// depends on the square, not on who is standing in it.
    static func clusterCentre(_ point: GreatCircle.Point) -> GreatCircle.Point {
        GreatCircle.Point(
            latitude: Double(String(format: "%.5f", point.latitude)) ?? point.latitude,
            longitude: Double(String(format: "%.5f", point.longitude)) ?? point.longitude)
    }

    /// Where one station sits in its cluster's fan, in metres north and east.
    ///
    /// Derived from the callsign alone, which is the whole point. The fan
    /// used to space stations evenly — `2pi * index / count` — and the
    /// comment beside it claimed the arrangement therefore never jittered.
    /// It only held for fixed membership: both the index and the count move
    /// when a station joins or leaves the square, so every *other* marker in
    /// that cluster jumped, by up to the fan radius, every time a new station
    /// was heard from the same grid. On a busy channel that is most of the
    /// time, and it is what made the map look unsettled.
    ///
    /// The cost is that spacing is no longer perfectly even, and two
    /// callsigns can hash to nearby bearings. The radius varies with the
    /// hash as well so they still separate, and a pair sitting a little
    /// closer than ideal beats every marker in a cluster moving whenever the
    /// radio hears someone new.
    static func fanOffset(callsign: String, radius: Double) -> (north: Double, east: Double) {
        let hash = stableHash(callsign)
        let bearing = 2 * Double.pi * Double(hash % 3_600) / 3_600
        // Never the full radius for everyone: two stations that land on
        // similar bearings are pushed apart by sitting on different rings.
        let ring = radius * (0.6 + 0.4 * Double((hash >> 24) % 1_000) / 1_000)
        return (ring * cos(bearing), ring * sin(bearing))
    }

    /// FNV-1a over the callsign's bytes.
    ///
    /// Swift's own `hashValue` is seeded per process, so a marker placed
    /// with it would sit somewhere different every launch — trading a jitter
    /// on redraw for a jitter on relaunch. This is fixed for all time.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// How many *other* stations share each station's exact position.
    static func sharedPositionCounts(_ entries: [Entry]) -> [String: Int] {
        var result = [String: Int]()
        for cluster in clusters(entries) where cluster.count > 1 {
            for entry in cluster {
                result[entry.callsign] = cluster.count - 1
            }
        }
        return result
    }

    /// The scope: one site per **station**, positioned by
    /// `fannedPositions` so stations sharing a grid square stay
    /// individually visible. Unplaced stations are absent — a map cannot
    /// show them, and inventing a position would be worse than the gap.
    static func scope(observerLabel: String,
                      observer: GreatCircle.Point,
                      entries: [Entry],
                      now: Date,
                      distanceInMiles: Bool = true) -> StationScope {
        let positions = fannedPositions(entries)
        let shared = sharedPositionCounts(entries)
        return StationScope.build(
            observerLabel: observerLabel,
            observer: observer,
            entries: entries.compactMap { entry in
                guard let position = positions[entry.callsign] else { return nil }
                var text = detail(for: entry, observer: observer, now: now,
                                  distanceInMiles: distanceInMiles)
                if let others = shared[entry.callsign], others > 0 {
                    text += entry.isExactPosition
                        ? "\n\nShares an exact position with "
                        : "\n\nShares grid \(entry.gridSquare ?? "square") with "
                    text += "\(others) other station\(others == 1 ? "" : "s"). "
                    text += entry.isExactPosition
                        ? "Markers are nudged apart only so each can be picked."
                        : "Markers are spread within the square so each can be picked; a grid reference gives no finer position than that."
                }
                return (
                    id: entry.callsign,
                    label: entry.callsign,
                    position: position,
                    signal: signal(for: entry, now: now),
                    subtitle: entry.gridSquare ?? "",
                    detail: text,
                    isStale: isStale(entry, now: now),
                    isApproximate: entry.confidence == .inferredFromOperator,
                    isNode: entry.isNodeAlias)
            })
    }

    /// For a heard station, recency *is* the signal — it is the only
    /// thing the receiver actually measured.
    static func signal(for entry: Entry, now: Date) -> StationScope.Signal {
        guard let lastHeard = entry.lastHeard else { return .unknown }
        let age = now.timeIntervalSince(lastHeard)
        if age <= activeWindow { return .good }
        if age <= staleWindow { return .fair }
        return .poor
    }

    static func isStale(_ entry: Entry, now: Date) -> Bool {
        guard let lastHeard = entry.lastHeard else { return true }
        return now.timeIntervalSince(lastHeard) > staleWindow
    }

    static func detail(for entry: Entry, observer: GreatCircle.Point, now: Date,
                       distanceInMiles: Bool = true) -> String {
        var lines = [entry.callsign]
        // A node wears two names and the operator needs both: the alias is
        // what the network answers to (`C INRMS` at a prompt), the
        // callsign is who is licensed to be there.
        if entry.isNodeAlias, let call = entry.nodeCallsign, call != entry.callsign {
            lines.append("Alias of \(call)")
        }
        if let name = entry.name { lines.append(name) }
        if let locality = entry.locality, let grid = entry.gridSquare {
            lines.append("\(locality) · \(grid)")
        } else if let grid = entry.gridSquare {
            lines.append(grid)
        }
        if let position = entry.position {
            let kilometres = GreatCircle.kilometres(from: observer, to: position)
            let bearing = GreatCircle.bearingDegrees(from: observer, to: position)
            lines.append(String(format: "%@ at %.0f° (%@)",
                                DistanceDisplay.string(
                                    kilometres: kilometres, inMiles: distanceInMiles),
                                bearing, GreatCircle.compassPoint(bearing)))
        }
        lines.append("\(entry.heardCount) packet\(entry.heardCount == 1 ? "" : "s") heard")
        if let lastHeard = entry.lastHeard {
            lines.append("Last heard \(lastHeard.formatted(.relative(presentation: .named)))")
        }
        if !entry.lastVia.isEmpty {
            lines.append("Via \(entry.lastVia.joined(separator: " \u{2192} "))")
        }
        if let source = entry.positionSource {
            lines.append("")
            lines.append("Position from \(source).")
        }
        return lines.joined(separator: "\n")
    }

    /// Callsigns worth asking a directory about: unplaced, and plausibly
    /// a licence rather than a tactical alias.
    static func lookupCandidates(_ entries: [Entry],
                                 aliases: NodeAliasDirectory = NodeAliasDirectory()) -> [String] {
        entries
            .filter { !$0.isPlaced }
            // A node alias is not a licence; what needs looking up is
            // the operator that announced it.
            .map { $0.isNodeAlias ? (aliases.callsign(for: $0.callsign) ?? "") : $0.callsign }
            .filter(CallsignQuery.isPlausible)
            .map(CallsignQuery.normalize)
            .reduce(into: [String]()) { unique, call in
                if !unique.contains(call) { unique.append(call) }
            }
    }

    /// Appends alias entries to heard ones, dropping any alias the radio has
    /// also heard directly.
    ///
    /// `DRLNOD` transmits its own beacons *and* appears as a hop in via
    /// paths, so it arrived once as a heard station and again as an alias
    /// placed through its operator — two entries with one callsign. Every
    /// consumer downstream keys on the callsign, so the pair drew as two
    /// stacked markers and trapped the map's annotation reconciler outright.
    /// The heard entry wins: it is the station itself, not a lead to it.
    static func addingAliases(_ nodes: [Entry], toHeard heard: [Entry]) -> [Entry] {
        let heardCalls = Set(heard.map { $0.callsign.uppercased() })
        return heard + nodes.filter { !heardCalls.contains($0.callsign.uppercased()) }
    }

    // MARK: - Node aliases

    /// Entries for NET/ROM aliases seen in via paths.
    ///
    /// An alias is a tactical name, so no callsign directory has one —
    /// but stations announce their aliases in ID beacons, and once
    /// `DRLNOD` is known to be `KE0NCQ` the ordinary chain places it.
    /// Its position is the operator's, which is exactly what a node's
    /// position is.
    ///
    /// Only aliases actually seen in a path are included: the point is
    /// to explain the hops this station's traffic takes, not to list
    /// every node ever announced.
    static func aliasEntries(aliases: NodeAliasDirectory,
                             usedAliases: Set<String>,
                             directory: [String: CallsignRecord],
                             stations: [Station]) -> [Entry] {
        let lastHeard = Dictionary(
            stations.map { ($0.call.uppercased(), $0.lastHeard) },
            uniquingKeysWith: { first, _ in first })

        return usedAliases.compactMap { alias -> Entry? in
            let key = alias.uppercased()
            guard let entry = aliases.entry(for: key) else { return nil }
            let base = CallsignQuery.normalize(entry.callsign)
            guard let record = directory[base], let position = record.position else {
                // The alias is known but its operator is not placed yet.
                // Listed unplaced rather than dropped — an alias in a
                // via path that cannot be located is a fact worth
                // showing, and it is what a lookup would fix.
                return Entry(
                    callsign: key, heardCount: 0,
                    lastHeard: lastHeard[entry.callsign.uppercased()] ?? nil,
                    lastVia: [],
                    positionSource: nil,
                    gridSquare: nil,
                    name: "Node operated by \(entry.callsign)",
                    isNodeAlias: true,
                    nodeCallsign: entry.callsign.uppercased())
            }
            return Entry(
                callsign: key,
                heardCount: 0,
                lastHeard: lastHeard[entry.callsign.uppercased()] ?? nil,
                lastVia: [],
                position: position,
                positionSource: "operator \(entry.callsign) (from its ID beacon), located by \(record.source)",
                confidence: .inferredFromOperator,
                gridSquare: record.gridSquare?.uppercased(),
                name: record.name,
                locality: record.locality,
                isNodeAlias: true,
                nodeCallsign: entry.callsign.uppercased())
        }
        .sorted { $0.callsign < $1.callsign }
    }

    /// Entries for the whole node directory — every station the network
    /// has claimed reachable, not only aliases seen in via paths.
    ///
    /// The directory is harvested hearsay and can run to hundreds of
    /// names, so this layer is deliberately bounded: only entries that can
    /// be *placed with what is already cached* are returned. No lookups
    /// are triggered — feeding five hundred harvested names to an online
    /// directory is exactly the bulk-fetch runaway the terrain downloader
    /// once had. Names that collide with a heard station or with the
    /// operator's own callsign are left to the heard layer, which knows
    /// more about them.
    static func directoryNodeEntries(aliases: NodeAliasDirectory,
                                     alreadyShown: Set<String>,
                                     shownCallsigns: Set<String> = [],
                                     directory: [String: CallsignRecord],
                                     announcedGrids: [String: String],
                                     stations: [Station],
                                     excluding ownCallsign: String = "") -> [Entry] {
        let own = CallsignQuery.normalize(ownCallsign)
        let shownBases = Set(shownCallsigns.map(CallsignQuery.normalize))
        let all = Set(aliases.allEntries.map { $0.alias.uppercased() })
        let candidates = all.subtracting(alreadyShown).filter { name in
            // An alias of a station already on the map — under *any* SSID
            // of the same base — is the same box wearing another hat.
            // YZBBPQ beside the heard KB5YZB-7 read as two stations
            // (2026-08-29 04:55), and ZIABBS (→ K0ZIA-1) still stood
            // beside the heard K0ZIA-14 after full-callsign matching
            // (05:24): a node's services live on sibling SSIDs of one
            // box, so the heard station owns the marker and this layer
            // draws only stations never heard at all.
            if let call = aliases.callsign(for: name),
               shownBases.contains(CallsignQuery.normalize(call)) { return false }
            guard !own.isEmpty else { return true }
            // Our own node alias resolves to our own callsign — the centre
            // marker already is this station.
            if CallsignQuery.normalize(name) == own { return false }
            if let call = aliases.callsign(for: name),
               CallsignQuery.normalize(call) == own { return false }
            return true
        }

        // One marker per physical station — grouped by *base* callsign,
        // because a node's services live on different SSIDs of one box:
        // ZIARMS, ZIABBS, ZIACHT and ZIABPQ resolve to K0ZIA-10, -1, -7
        // and -2 and drew four diamonds at one address (field capture
        // 2026-08-29 05:16). All of these place at the same operator
        // address anyway, so collapsing by base loses no position. The
        // first alias stands for the box; the others ride along in its
        // detail text.
        var byCallsign: [String: [String]] = [:]
        for name in candidates {
            let key = aliases.callsign(for: name).map(CallsignQuery.normalize) ?? name
            byCallsign[key, default: []].append(name)
        }
        var representatives: Set<String> = []
        var siblings: [String: [String]] = [:]
        for names in byCallsign.values {
            let sorted = names.sorted()
            representatives.insert(sorted[0])
            if sorted.count > 1 {
                siblings[sorted[0]] = Array(sorted.dropFirst())
            }
        }

        return aliasEntries(aliases: aliases,
                            usedAliases: representatives,
                            directory: directory,
                            stations: stations)
            .compactMap { entry -> Entry? in
                var entry = entry
                if let others = siblings[entry.callsign] {
                    let base = entry.name ?? "Node"
                    entry.name = "\(base) — also \(others.joined(separator: ", "))"
                }
                let placed = placingFromAnnouncedGrid(
                    entry, aliases: aliases, announcedGrids: announcedGrids)
                return placed.isPlaced ? placed : nil
            }
    }

    /// Places an alias from a locator it beaconed itself, if it is not
    /// placed already.
    ///
    /// Shared by both node layers, and it has to be. The via-path aliases in
    /// `coreEntries` and the rest of the directory are the same kind of
    /// thing, drawn from the same table, differing only in whether traffic
    /// has lately used them — and traffic moves an alias between the two as
    /// via paths change. When only the directory layer knew this step, an
    /// alias placed by its own beacon appeared while it sat in that layer
    /// and vanished the moment a packet routed through it, because the core
    /// layer could not place it and the directory layer no longer claimed
    /// it. Then it came back. That flapping is what the map's remaining
    /// pulse turned out to be (field log 2026-09-01: the same fifteen BBS
    /// aliases arriving and departing together).
    ///
    /// A locator the station announced beats its operator's licence
    /// address, so this is a genuine refinement rather than a fallback.
    static func placingFromAnnouncedGrid(_ entry: Entry,
                                         aliases: NodeAliasDirectory,
                                         announcedGrids: [String: String]) -> Entry {
        guard !entry.isPlaced else { return entry }
        let call = aliases.callsign(for: entry.callsign)?.uppercased()
        guard let grid = call.flatMap({ announcedGrids[$0] }),
              let center = Maidenhead.center(of: grid) else { return entry }
        var entry = entry
        entry.position = GreatCircle.Point(center)
        entry.positionSource = "locator announced in its own beacon"
        entry.confidence = .gridSquare
        entry.gridSquare = grid.uppercased()
        return entry
    }

    /// Operator callsigns worth asking a directory about to place more of
    /// the node layer — bounded and ordered by how many nodes vouch for
    /// each station, because "look up everything" is the bulk-fetch
    /// runaway the terrain downloader taught. Only runs on the operator's
    /// explicit Find Positions press, never automatically.
    ///
    /// Bases already heard are excluded: their boxes fold into the heard
    /// markers and can never draw a diamond, so a lookup for them spends
    /// the press's budget on nothing visible (field capture 2026-08-29
    /// 05:35 — the first batches went to local well-vouched families and
    /// the layer ended up nearly empty).
    static func directoryLookupCandidates(aliases: NodeAliasDirectory,
                                          cachedCallsigns: Set<String>,
                                          heardBases: Set<String> = [],
                                          limit: Int = 40) -> [String] {
        directoryOperatorCallsigns(aliases: aliases)
            .filter { !cachedCallsigns.contains($0) && !heardBases.contains($0) }
            .prefix(limit).map { $0 }
    }

    /// Every operator callsign the alias directory names, best-vouched
    /// first — the whole set whose positions this layer draws from,
    /// unfiltered.
    ///
    /// Separate from `directoryLookupCandidates` because the two questions
    /// are not the same one. Asking a remote directory has to be rationed
    /// and has to skip what is already known; reading this app's own cache
    /// wants the complete list, because a position sitting in the local
    /// cache and not in memory is a marker the map is failing to draw for
    /// no reason at all.
    static func directoryOperatorCallsigns(aliases: NodeAliasDirectory) -> [String] {
        aliases.allEntries
            .sorted { ($0.tellers.count, $1.alias) > ($1.tellers.count, $0.alias) }
            .map { CallsignQuery.normalize($0.callsign) }
            .filter { CallsignQuery.isPlausible($0) }
            .reduce(into: [String]()) { unique, call in
                if !unique.contains(call) { unique.append(call) }
            }
    }

    /// The directory aliases that fold into heard stations, by base
    /// callsign — so the heard marker can *say* it is the node instead of
    /// the fold being silent. ZIABBS and friends vanished from the layer
    /// when K0ZIA-14 was heard, correctly — but nothing then told the
    /// operator that the yellow dot IS the ZIA node.
    static func nodeAliasesByHeardBase(aliases: NodeAliasDirectory,
                                       heardCalls: Set<String>) -> [String: [String]] {
        let bases = Set(heardCalls.map(CallsignQuery.normalize))
        var result: [String: [String]] = [:]
        for entry in aliases.allEntries {
            let base = CallsignQuery.normalize(entry.callsign)
            guard bases.contains(base),
                  entry.alias.uppercased() != entry.callsign.uppercased()
            else { continue }
            result[base, default: []].append(entry.alias.uppercased())
        }
        return result.mapValues { $0.sorted() }
    }

    /// Aliases appearing in the via paths of stations actually heard.
    static func aliasesInUse(_ stations: [Station]) -> Set<String> {
        var result = Set<String>()
        for station in stations {
            for hop in station.lastVia {
                let name = hop.uppercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                // A hop that is itself a callsign is a digipeating
                // station, not an alias.
                guard !CallsignQuery.isPlausible(name) else { continue }
                guard NodeAliasParser.isPlausibleAlias(name) else { continue }
                result.insert(name)
            }
        }
        return result
    }
}
