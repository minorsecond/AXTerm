import Foundation

/// A path nobody has used, judged by the ground between the two stations.
///
/// Everything else AXTerm knows about paths is a record of what has already
/// happened. This is the one thing that says something about a path *before*
/// the first transmission: two stations that have never exchanged a frame
/// either have a ridge between them or they do not, and the terrain data
/// already on the device can tell which.
///
/// For an operator planning where to go, that is the difference between "I
/// know nothing about that valley" and "from this ridge you would reach these
/// four nodes, and this fifth one is blocked by Mount Evans".
nonisolated struct PredictedPath: Equatable, Sendable, Identifiable {

    enum Outlook: Equatable, Sendable {
        /// Line of sight with the Fresnel zone essentially clear.
        case promising(worstFresnelRatio: Double)
        /// Line of sight, but the zone is intruded on. The "answers but
        /// struggles" signature.
        case marginal(worstFresnelRatio: Double)
        /// Terrain is above the line.
        case blocked(byMetres: Double, atMetres: Double)

        var label: String {
            switch self {
            case .promising: return "Clear path"
            case .marginal: return "Marginal"
            case .blocked: return "Blocked"
            }
        }

        /// Says what the geometry is, not merely a verdict — an operator who
        /// disagrees should be able to see what the app measured.
        var explanation: String {
            switch self {
            case .promising(let ratio):
                return String(format: "Line of sight with %.0f%% of the first Fresnel zone clear. This path has never been tried, but nothing on the ground is in the way.", min(ratio, 2) * 100)
            case .marginal(let ratio):
                return String(format: "Line of sight exists, but terrain intrudes into the Fresnel zone — only %.0f%% of it is clear, against the 60%% a path needs to behave like an open one. Expect a link that works and struggles.", max(ratio, 0) * 100)
            case .blocked(let metres, let at):
                return String(format: "Terrain rises %.0f m above the line %.1f km along the path. There is no line of sight; anything getting through would be diffraction.", metres, at / 1000)
            }
        }
    }

    var from: String
    var to: String
    var outlook: Outlook
    var distanceKilometres: Double
    /// True when at least one end's antenna height was assumed rather than
    /// recorded. The verdict is only as good as that guess, and the label
    /// says so rather than presenting a forecast built on a default as if it
    /// were built on a measurement.
    var assumedHeights: Bool = true

    var id: String {
        let ends = [from.uppercased(), to.uppercased()].sorted()
        return "predicted|\(ends[0])~\(ends[1])"
    }

    /// How much height would open this path, where terrain is in the way.
    ///
    /// The most actionable number the terrain model produces. A path blocked
    /// by four metres is not a dead path — it is a path that wants a taller
    /// mast, and saying so is worth more than hiding the line.
    var blockedByMetres: Double? {
        if case .blocked(let metres, _) = outlook { return metres }
        return nil
    }

    /// Whether this is worth showing at all.
    ///
    /// A blocked path is a real finding — it explains why a station is not
    /// heard — but drawing every blocked pair on a busy map would be a mesh
    /// of lines saying "no". Only the encouraging ones are drawn; the rest
    /// answer a question when asked about one station.
    var isWorthDrawing: Bool {
        switch outlook {
        case .promising, .marginal: return true
        case .blocked: return false
        }
    }

    // MARK: - Building

    /// Judges the untried paths between placed stations.
    ///
    /// - Parameters:
    ///   - alreadyObserved: paths with real evidence, which need no
    ///     prediction — a path that has carried a frame is not a forecast.
    ///   - heights: metres above ground per station, where somebody has
    ///     recorded it. Height is the input that most often decides the
    ///     verdict, so a real one is worth far more here than any refinement
    ///     to the sampling.
    ///   - defaultHeightMetres: used for every station not in `heights`. A
    ///     guess, and named as one: neither the CMS nor the licence directory
    ///     records antenna height, so this is a stated assumption rather than
    ///     a measurement.
    ///   - maximumKilometres: paths beyond this are not evaluated. Terrain
    ///     analysis over hundreds of kilometres is dominated by the earth's
    ///     curvature rather than by the ground, and the answer would be "no"
    ///     without needing the elevation data to say so.
    static func predictions(
        between positions: [String: GreatCircle.Point],
        alreadyObserved: [NetworkPath],
        sampler: ElevationSampling,
        frequencyHz: Double,
        heights: [String: Double] = [:],
        defaultHeightMetres: Double = 10,
        maximumKilometres: Double = 120,
        limit: Int = 60,
        maximumProfiles: Int = 400
    ) -> [PredictedPath] {

        func height(_ callsign: String) -> Double {
            // A recorded zero is still "on the ground", which is a legitimate
            // answer for a handheld; only a missing entry falls back.
            heights[callsign.uppercased()] ?? defaultHeightMetres
        }

        let known = Set(alreadyObserved.map(\.id))
        let names = positions.keys.sorted()

        // Candidates are gathered before any terrain is sampled, and sorted
        // by distance.
        //
        // Order matters more than it looks. Walking the pairs alphabetically
        // and stopping at a fixed count spends the whole budget on whichever
        // callsigns sort first, which has nothing to do with which paths are
        // worth knowing about. Nearest-first is both cheaper to be wrong
        // about and the order an operator cares about: a 9 km path that works
        // is more use than a 90 km one that might.
        var candidates: [(a: String, b: String,
                          from: GreatCircle.Point, to: GreatCircle.Point,
                          distance: Double)] = []
        for i in names.indices {
            for j in names.index(after: i)..<names.endIndex {
                let a = names[i], b = names[j]
                guard let from = positions[a], let to = positions[b] else { continue }

                // Same point — different SSIDs of one licence resolved through
                // one address. There is no path to analyse.
                guard from != to else { continue }

                let distance = GreatCircle.kilometres(from: from, to: to)
                guard distance <= maximumKilometres else { continue }

                // A path already carrying traffic needs no forecast.
                let ends = [a, b].sorted()
                let pairKey = "\(ends[0])~\(ends[1])"
                if known.contains(where: { $0.hasPrefix(pairKey) }) { continue }

                candidates.append((a, b, from, to, distance))
            }
        }
        // Distance decides, callsign breaks ties, so the same inputs always
        // produce the same forecasts in the same order.
        candidates.sort {
            $0.distance == $1.distance
                ? ($0.a, $0.b) < ($1.a, $1.b)
                : $0.distance < $1.distance
        }

        var result: [PredictedPath] = []
        var drawable = 0
        for candidate in candidates.prefix(maximumProfiles) {
            let profile = TerrainProfile.between(
                origin: candidate.from, destination: candidate.to,
                originHeight: height(candidate.a),
                destinationHeight: height(candidate.b),
                frequencyHz: frequencyHz,
                sampler: sampler)

            guard let outlook = outlook(for: profile.verdict) else { continue }
            let path = PredictedPath(
                from: candidate.a, to: candidate.b, outlook: outlook,
                distanceKilometres: candidate.distance,
                assumedHeights: heights[candidate.a.uppercased()] == nil
                    || heights[candidate.b.uppercased()] == nil)
            result.append(path)

            // The budget counts paths worth *drawing*. Counting blocked ones
            // against it meant a region where most paths are blocked — which
            // is most rolling terrain at modest antenna heights — exhausted
            // the quota before reaching a single workable path, and the map
            // drew nothing while reporting it had checked sixty.
            if path.isWorthDrawing {
                drawable += 1
                if drawable >= limit { break }
            }
        }
        return result
    }

    /// Nil where the elevation data cannot answer.
    ///
    /// A gap in coverage read as "clear" would be the most dangerous possible
    /// way to be wrong: it would draw an encouraging line across a mountain.
    static func outlook(for verdict: TerrainProfile.Verdict) -> Outlook? {
        switch verdict {
        case .clear(let ratio):
            return .promising(worstFresnelRatio: ratio)
        case .marginal(let ratio, _):
            return .marginal(worstFresnelRatio: ratio)
        case .obstructed(let metres, let at):
            return .blocked(byMetres: metres, atMetres: at)
        case .unknown:
            return nil
        }
    }
}
