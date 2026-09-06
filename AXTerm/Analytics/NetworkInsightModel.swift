import Foundation
import Combine

/// What the observed network *means*, computed away from the views.
///
/// Three questions the raw path list cannot answer by itself:
///
/// - **Which station is the single point of failure?** An articulation point
///   is a vertex whose removal splits the graph. On a packet network that is
///   almost always a digipeater on a hill, and it is worth knowing before it
///   goes off the air rather than after.
/// - **Which stations form a cluster?** Label propagation finds groups that
///   talk to each other more than they talk outward, which is what a "local
///   network" actually is when nobody broadcasts NODES.
/// - **Where could a path exist that has never been tried?** Terrain answers
///   that without transmitting anything.
///
/// All three are cheap for a few dozen stations and quadratic-ish beyond, and
/// the terrain pass reads the elevation database, so this runs off the main
/// actor and publishes a finished snapshot.
@MainActor
final class NetworkInsightModel: ObservableObject {

    // Nonisolated: it is built inside a detached task and declared Sendable
    // precisely so it can cross back. Only the project's main-actor default
    // put its memberwise initialiser on the main actor.
    nonisolated struct Snapshot: Equatable, Sendable {
        /// Stations whose loss would split the network, with what it splits
        /// into. The partition sizes are the point: "removing this isolates
        /// four stations" is actionable, "this is an articulation point" is
        /// vocabulary.
        var criticalStations: [String: [Int]] = [:]
        /// Callsign → community identifier (the alphabetically first member,
        /// so the identity is stable between runs).
        var communities: [String: String] = [:]
        /// Terrain forecasts for pairs that have never been observed talking.
        var predictions: [PredictedPath] = []
        /// True when terrain was asked for but no elevation tiles covered the
        /// stations. Distinguished from "asked and found nothing", because
        /// silence for those two reasons means opposite things.
        var terrainUnavailable = false

        var isEmpty: Bool {
            criticalStations.isEmpty && communities.isEmpty && predictions.isEmpty
        }

        /// Forecasts good enough to draw.
        var drawablePredictions: [PredictedPath] {
            predictions.filter(\.isWorthDrawing)
        }

        /// The blocked path that comes closest to working, if any.
        ///
        /// Exists because "every path is blocked" is a perfectly ordinary
        /// outcome in rolling terrain at modest antenna heights, and it
        /// renders as an empty map. An empty map is indistinguishable from a
        /// broken feature. The near miss turns that silence into the one
        /// sentence worth reading: how much height would open the best path.
        var closestBlocked: PredictedPath? {
            predictions
                .filter { $0.blockedByMetres != nil }
                .min { ($0.blockedByMetres ?? .infinity) < ($1.blockedByMetres ?? .infinity) }
        }
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var isWorking = false

    /// Terrain lookups need the elevation database; without one the first two
    /// analyses still run.
    var elevationStore: ElevationStore?

    private var task: Task<Void, Never>?
    /// Skips recomputation when nothing that feeds it has changed. The map
    /// re-renders on every packet, and re-running terrain each time would be
    /// a background thread permanently at full tilt.
    private var lastFingerprint: String?

    func refresh(paths: [NetworkPath],
                 positions: [String: GreatCircle.Point],
                 frequencyHz: Double,
                 heights: [String: Double] = [:],
                 defaultHeightMetres: Double = 10,
                 wantsTerrain: Bool) {
        let fingerprint = Self.fingerprint(
            paths: paths, positions: positions,
            frequencyHz: frequencyHz, heights: heights,
            defaultHeightMetres: defaultHeightMetres,
            wantsTerrain: wantsTerrain)
        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint

        task?.cancel()
        let store = elevationStore
        isWorking = true
        task = Task { [weak self] in
            let result = await Self.compute(
                paths: paths, positions: positions,
                frequencyHz: frequencyHz,
                heights: heights, defaultHeightMetres: defaultHeightMetres,
                store: wantsTerrain ? store : nil)
            guard !Task.isCancelled else { return }
            self?.snapshot = result
            self?.isWorking = false
        }
    }

    private static func compute(paths: [NetworkPath],
                                positions: [String: GreatCircle.Point],
                                frequencyHz: Double,
                                heights: [String: Double],
                                defaultHeightMetres: Double,
                                store: ElevationStore?) async -> Snapshot {
        await Task.detached(priority: .utility) {
            var snapshot = Snapshot()
            let graph = NetworkTopology.adjacency(paths)

            for vertex in NetworkTopology.articulationPoints(in: graph) {
                let partitions = NetworkTopology.partitionsWithout(vertex, in: graph)
                snapshot.criticalStations[vertex] = partitions.map(\.count).sorted(by: >)
            }
            snapshot.communities = NetworkTopology.communities(in: graph)

            if let store {
                let sampler = StoredElevationSampler(store: store)
                // If nothing under the stations has been downloaded, say so
                // rather than reporting an empty forecast, which reads as
                // "no paths possible".
                let covered = positions.values.contains { sampler.elevation(at: $0) != nil }
                if covered {
                    snapshot.predictions = PredictedPath.predictions(
                        between: positions, alreadyObserved: paths,
                        sampler: sampler, frequencyHz: frequencyHz,
                        heights: heights,
                        defaultHeightMetres: defaultHeightMetres)
                } else {
                    snapshot.terrainUnavailable = true
                }
            }
            return snapshot
        }.value
    }

    /// Cheap identity for the inputs. Path evidence is included because an
    /// upgrade from inferred to observed changes the graph.
    private static func fingerprint(paths: [NetworkPath],
                                    positions: [String: GreatCircle.Point],
                                    frequencyHz: Double,
                                    heights: [String: Double],
                                    defaultHeightMetres: Double,
                                    wantsTerrain: Bool) -> String {
        let pathPart = paths.map { "\($0.id):\($0.evidence.rawValue)" }.sorted().joined(separator: ",")
        let placePart = positions.keys.sorted().joined(separator: ",")
        // Heights are in the key because changing one changes every verdict
        // the station appears in — the whole point of asking for them.
        let heightPart = heights.keys.sorted().map { "\($0):\(heights[$0] ?? 0)" }
            .joined(separator: ",")
        return "\(pathPart)|\(placePart)|\(Int(frequencyHz))|\(heightPart)|\(defaultHeightMetres)|\(wantsTerrain)"
    }
}
