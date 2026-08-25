import Foundation

/// Graph analysis over the paths observed on the channel.
///
/// Everything here is a pure function of the observed topology. None of it
/// transmits, and none of it needs the network to cooperate — which is the
/// point, because the networks that most need analysing are the ones with no
/// routing protocol running on them.
nonisolated enum NetworkTopology {

    /// Adjacency built from paths, treating every path as an undirected edge.
    ///
    /// Digipeaters are included as vertices in their own right rather than
    /// being collapsed into the paths that use them. That is the whole reason
    /// the analysis is interesting: a digipeater is usually the vertex whose
    /// removal breaks everything, and hiding it inside an edge would make it
    /// impossible to notice.
    static func adjacency(_ paths: [NetworkPath],
                          minimumEvidence: NetworkPath.Evidence = .heardDirect)
        -> [String: Set<String>] {
        var graph: [String: Set<String>] = [:]

        func connect(_ a: String, _ b: String) {
            guard a != b else { return }
            graph[a, default: []].insert(b)
            graph[b, default: []].insert(a)
        }

        for path in paths where path.evidence >= minimumEvidence {
            let hops = [path.from.uppercased()]
                + path.via.map { $0.uppercased() }
                + [path.to.uppercased()]
            for index in hops.indices.dropLast() {
                connect(hops[index], hops[index + 1])
            }
        }
        return graph
    }

    // MARK: - Articulation points

    /// Stations whose loss would split the network.
    ///
    /// Tarjan's algorithm: a vertex is a cut vertex when some child in the
    /// depth-first tree cannot reach an ancestor except through it. On a
    /// packet network that is the difference between "this node is busy" and
    /// "this node is the only way through", and no amount of link-quality
    /// measurement reveals it — quality describes edges, and this is a fact
    /// about the shape of the whole graph.
    ///
    /// Iterative rather than recursive: a deep chain of digipeaters would
    /// otherwise put the stack depth at the mercy of someone else's network.
    static func articulationPoints(in graph: [String: Set<String>]) -> Set<String> {
        var discovery: [String: Int] = [:]
        var low: [String: Int] = [:]
        var parent: [String: String] = [:]
        var result: Set<String> = []
        var timer = 0

        for root in graph.keys.sorted() where discovery[root] == nil {
            var rootChildren = 0
            // (vertex, iterator over its neighbours)
            var stack: [(String, Array<String>.Index)] = []
            let neighbours = { (v: String) in graph[v]?.sorted() ?? [] }

            discovery[root] = timer
            low[root] = timer
            timer += 1
            var lists: [String: [String]] = [root: neighbours(root)]
            stack.append((root, 0))

            while let (vertex, index) = stack.last {
                let list = lists[vertex] ?? []
                if index < list.count {
                    stack[stack.count - 1].1 = index + 1
                    let next = list[index]
                    if discovery[next] == nil {
                        parent[next] = vertex
                        if vertex == root { rootChildren += 1 }
                        discovery[next] = timer
                        low[next] = timer
                        timer += 1
                        lists[next] = neighbours(next)
                        stack.append((next, 0))
                    } else if parent[vertex] != next {
                        low[vertex] = min(low[vertex] ?? 0, discovery[next] ?? 0)
                    }
                } else {
                    stack.removeLast()
                    if let above = stack.last?.0 {
                        low[above] = min(low[above] ?? 0, low[vertex] ?? 0)
                        // A non-root vertex is a cut vertex when a child's
                        // subtree cannot climb above it.
                        if above != root, (low[vertex] ?? 0) >= (discovery[above] ?? 0) {
                            result.insert(above)
                        }
                    }
                }
            }
            // The root is a cut vertex only when it has more than one child:
            // with one child, removing it leaves that subtree intact.
            if rootChildren > 1 { result.insert(root) }
        }
        return result
    }

    /// Which stations become unreachable from the rest if one is removed.
    ///
    /// Turns "DRLNOD is an articulation point" into "and these eight stations
    /// are what you lose", which is the form an operator can act on.
    static func partitionsWithout(_ vertex: String,
                                  in graph: [String: Set<String>]) -> [Set<String>] {
        var remaining = graph
        remaining.removeValue(forKey: vertex.uppercased())
        for key in remaining.keys {
            remaining[key]?.remove(vertex.uppercased())
        }

        var seen: Set<String> = []
        var components: [Set<String>] = []
        for start in remaining.keys.sorted() where !seen.contains(start) {
            var component: Set<String> = []
            var queue = [start]
            while let current = queue.popLast() {
                guard seen.insert(current).inserted else { continue }
                component.insert(current)
                queue += (remaining[current] ?? []).filter { !seen.contains($0) }
            }
            components.append(component)
        }
        return components.sorted { $0.count > $1.count }
    }

    // MARK: - Communities

    /// Sub-networks discovered from who talks to whom.
    ///
    /// Label propagation: every vertex repeatedly adopts the commonest label
    /// among its neighbours until nothing changes. Chosen over modularity
    /// optimisation because it needs no parameters and no target count — on a
    /// packet channel nobody knows in advance how many club networks share the
    /// frequency, and a method that has to be told would be answering its own
    /// question.
    ///
    /// Ties break toward the alphabetically lowest label so the result is the
    /// same on every run. Non-determinism here would repaint the map on every
    /// redraw, which reads as the network changing when nothing has.
    static func communities(in graph: [String: Set<String>],
                            maximumRounds: Int = 20) -> [String: String] {
        var labels: [String: String] = [:]
        for vertex in graph.keys { labels[vertex] = vertex }

        let order = graph.keys.sorted()
        for _ in 0..<maximumRounds {
            var changed = false
            for vertex in order {
                let neighbours = graph[vertex] ?? []
                guard !neighbours.isEmpty else { continue }

                var counts: [String: Int] = [:]
                for neighbour in neighbours {
                    guard let label = labels[neighbour] else { continue }
                    counts[label, default: 0] += 1
                }
                guard let best = counts
                    .sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) })
                    .first?.key else { continue }
                if labels[vertex] != best {
                    labels[vertex] = best
                    changed = true
                }
            }
            if !changed { break }
        }
        return labels
    }

    /// Communities as sets, largest first, singletons dropped.
    ///
    /// A station that talks to nobody is not a network of one — presenting it
    /// as a community would fill the map with colours that mean nothing.
    static func communityGroups(in graph: [String: Set<String>]) -> [Set<String>] {
        Dictionary(grouping: communities(in: graph), by: \.value)
            .values
            .map { Set($0.map(\.key)) }
            .filter { $0.count > 1 }
            .sorted { ($1.count, $0.sorted().first ?? "") < ($0.count, $1.sorted().first ?? "") }
    }
}
