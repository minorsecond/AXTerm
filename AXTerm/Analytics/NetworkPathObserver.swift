import Foundation

/// A path between two stations, and what makes us believe in it.
///
/// Distinct from `NetRomRouter`'s routes, which answer "how would *we* reach
/// this destination". This answers "what paths exist on this channel at all",
/// including ones between two other stations that we merely overhear. On a
/// network with no NET/ROM broadcasts that overhearing is the only source of
/// topology there is.
nonisolated struct NetworkPath: Equatable, Sendable, Identifiable {

    /// What was observed, ordered weakest to strongest.
    ///
    /// The ordering is the point: a path that completed a handshake is known
    /// to work in both directions, while one inferred from two separate links
    /// has never been tried end to end. Presenting those as the same fact
    /// would turn a guess into a recommendation.
    enum Evidence: Int, Equatable, Sendable, Comparable, CaseIterable {
        /// A and B each have a working link to D, so A may reach B through D.
        /// Never actually attempted.
        case transitive
        /// A frame from A to B was overheard travelling directly.
        case heardDirect
        /// A frame from A to B was overheard after a digipeater repeated it,
        /// so every hop in the path did its job at least once.
        case heardDigipeated
        /// A connect request was answered over this path. Both directions
        /// carried a frame end to end, which nothing else here proves.
        case sessionEstablished

        static func < (lhs: Evidence, rhs: Evidence) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .transitive: return "Inferred"
            case .heardDirect: return "Heard direct"
            case .heardDigipeated: return "Digipeated"
            case .sessionEstablished: return "Session completed"
            }
        }

        var explanation: String {
            switch self {
            case .transitive:
                return "Both ends have a working link to the same digipeater, so this path is plausible — but nothing has been observed travelling it."
            case .heardDirect:
                return "A frame was overheard passing directly between these stations."
            case .heardDigipeated:
                return "A frame was overheard arriving through this digipeater path, so every hop repeated it at least once."
            case .sessionEstablished:
                return "A connect request was answered over this path. Frames crossed it in both directions, which is the only evidence here that proves a path end to end."
            }
        }
    }

    var from: String
    var to: String
    /// Digipeaters in order. Empty means direct.
    var via: [String]
    var evidence: Evidence
    var observations: Int
    var firstSeen: Date
    var lastSeen: Date
    /// Connect attempts over this path that were never answered.
    var unansweredAttempts: Int

    /// Undirected identity — a path between two stations is one path, and
    /// listing A→B and B→A separately would double every edge on a map.
    var id: String {
        let ends = [from.uppercased(), to.uppercased()].sorted()
        return "\(ends[0])~\(ends[1])|\(via.joined(separator: ","))"
    }

    /// Combines what was stored with what the live window shows.
    ///
    /// Merge rules follow from where each field comes from:
    ///
    /// - **evidence** takes the stronger. Evidence is a claim about what has
    ///   been proven, and proof does not expire because a quiet hour passed.
    /// - **firstSeen** takes the earlier, **lastSeen** the later.
    /// - **unansweredAttempts** takes the larger — a high-water mark, so a
    ///   path that failed four times last week is not laundered clean by one
    ///   fresh window that never tried it.
    /// - **observations** takes the larger rather than the sum. This
    ///   understates a busy path, and does so deliberately: the live count is
    ///   derived from a rolling window that is re-derived every few seconds,
    ///   so summing would inflate it without bound. The number means "the
    ///   most this path was seen carrying in one window", not a lifetime
    ///   total, and nothing in the graph reads it as one.
    ///
    /// Merging the other way round must give the same answer, because the
    /// caller should never have to care which side is "stored".
    static func merged(_ lhs: NetworkPath, _ rhs: NetworkPath) -> NetworkPath {
        var result = lhs.evidence >= rhs.evidence ? lhs : rhs
        result.observations = max(lhs.observations, rhs.observations)
        result.firstSeen = min(lhs.firstSeen, rhs.firstSeen)
        result.lastSeen = max(lhs.lastSeen, rhs.lastSeen)
        result.unansweredAttempts = max(lhs.unansweredAttempts, rhs.unansweredAttempts)
        return result
    }

    /// Folds a mixed list down to one entry per path.
    static func merging(_ paths: [NetworkPath]) -> [NetworkPath] {
        var byID: [String: NetworkPath] = [:]
        for path in paths {
            byID[path.id] = byID[path.id].map { merged($0, path) } ?? path
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// True when connect attempts have gone unanswered and nothing has ever
    /// completed. Worth drawing differently: a path that looks plausible and
    /// does not work is the one that wastes the most airtime.
    var isSuspect: Bool {
        unansweredAttempts >= 2 && evidence < .sessionEstablished
    }
}

/// Builds the picture of what paths exist from overheard traffic.
///
/// Every heuristic here is passive. Nothing is transmitted to find out.
nonisolated struct NetworkPathObserver {

    /// How long a connect request waits for its answer before the attempt is
    /// counted as unanswered.
    ///
    /// AX.25 T1 starts around 4s and backs off; a node that is going to answer
    /// usually does so within a couple of retries. Two minutes is generous
    /// enough that a slow but working path is not libelled, and short enough
    /// that a genuinely dead path is recognised while the operator still cares.
    static let answerWindow: TimeInterval = 120

    /// Derives paths from a window of traffic.
    static func paths(in packets: [Packet], localCallsign: String = "") -> [NetworkPath] {
        var byID: [String: NetworkPath] = [:]
        // A list, not a single value: a node called every six seconds and
        // never answered is four pieces of negative evidence, and keeping only
        // the latest would score that the same as one polite retry.
        var pendingConnects: [String: [(date: Date, path: NetworkPath)]] = [:]

        func merge(_ candidate: NetworkPath) {
            if var existing = byID[candidate.id] {
                existing.observations += candidate.observations
                existing.evidence = max(existing.evidence, candidate.evidence)
                existing.firstSeen = min(existing.firstSeen, candidate.firstSeen)
                existing.lastSeen = max(existing.lastSeen, candidate.lastSeen)
                existing.unansweredAttempts += candidate.unansweredAttempts
                byID[candidate.id] = existing
            } else {
                byID[candidate.id] = candidate
            }
        }

        for packet in packets {
            guard let from = packet.from?.display.uppercased(),
                  let to = packet.to?.display.uppercased() else { continue }
            // Destinations like BEACON and ID are not stations, so a "path"
            // to one is a category error rather than topology.
            guard !CallsignValidator.isServiceEndpoint(to) else { continue }
            guard from != to else { continue }

            // Only hops that actually repeated count as part of the path an
            // observed frame travelled. An unrepeated hop is a request.
            let repeatedHops = packet.via.filter(\.repeated).map { $0.display.uppercased() }
            let evidence: NetworkPath.Evidence =
                repeatedHops.isEmpty ? .heardDirect : .heardDigipeated

            let path = NetworkPath(
                from: from, to: to, via: repeatedHops,
                evidence: evidence, observations: 1,
                firstSeen: packet.timestamp, lastSeen: packet.timestamp,
                unansweredAttempts: 0)
            merge(path)

            // A connect request opens a question; its answer closes it.
            switch connectRole(of: packet) {
            case .request:
                pendingConnects[path.id, default: []].append((packet.timestamp, path))
            case .answer:
                // One answer clears every outstanding request on that path:
                // the retries were all asking the same question.
                if let waiting = pendingConnects.removeValue(forKey: path.id),
                   let earliest = waiting.map(\.date).min(),
                   packet.timestamp.timeIntervalSince(earliest) <= answerWindow {
                    var proven = path
                    proven.evidence = .sessionEstablished
                    proven.lastSeen = packet.timestamp
                    merge(proven)
                }
            case .none:
                break
            }
        }

        // Anything still waiting when the window closes was never answered.
        // Negative evidence is worth as much as positive: a plausible-looking
        // path that never answers is the one that wastes the most airtime.
        let latest = packets.compactMap(\.timestamp).max() ?? Date()
        for (id, waiting) in pendingConnects {
            let expired = waiting.filter {
                latest.timeIntervalSince($0.date) > answerWindow
            }.count
            guard expired > 0, var existing = byID[id] else { continue }
            existing.unansweredAttempts += expired
            byID[id] = existing
        }

        return byID.values.sorted { ($1.evidence, $0.id) < ($0.evidence, $1.id) }
    }

    private enum ConnectRole { case request, answer, none }

    /// SABM opens a link; UA accepts it. DM is a refusal — the station is
    /// reachable but not listening, which says the *path* works even though
    /// the session did not.
    private static func connectRole(of packet: Packet) -> ConnectRole {
        guard packet.frameType == .u else { return .none }
        switch packet.control & 0xEF {
        case 0x2F: return .request   // SABM
        case 0x63: return .answer    // UA
        case 0x0F: return .answer    // DM — refused, but it answered
        default: return .none
        }
    }

    /// Paths nobody has travelled, but which both ends could plausibly use.
    ///
    /// If A reaches digipeater D and B reaches D, then A may reach B through
    /// D. Kept at the weakest evidence level on purpose: this has never been
    /// tried, and presenting it beside a completed session would turn a guess
    /// into a recommendation.
    static func transitivePaths(from observed: [NetworkPath],
                                now: Date = Date()) -> [NetworkPath] {
        // Which stations each digipeater has been seen relaying for.
        var reach: [String: Set<String>] = [:]
        for path in observed where path.evidence >= .heardDigipeated {
            for hop in path.via {
                reach[hop, default: []].insert(path.from)
                reach[hop, default: []].insert(path.to)
            }
        }

        var existing = Set(observed.map(\.id))
        var result: [NetworkPath] = []
        for (digi, stations) in reach where stations.count >= 2 {
            let sorted = stations.sorted()
            for i in sorted.indices {
                for j in sorted.index(after: i)..<sorted.endIndex {
                    let candidate = NetworkPath(
                        from: sorted[i], to: sorted[j], via: [digi],
                        evidence: .transitive, observations: 0,
                        firstSeen: now, lastSeen: now, unansweredAttempts: 0)
                    guard !existing.contains(candidate.id) else { continue }
                    existing.insert(candidate.id)
                    result.append(candidate)
                }
            }
        }
        return result
    }
}
