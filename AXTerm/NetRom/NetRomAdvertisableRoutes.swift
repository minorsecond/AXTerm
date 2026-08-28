//
//  NetRomAdvertisableRoutes.swift
//  AXTerm
//
//  Which of this station's routes are honest to publish.
//
//  A NODES broadcast is not a description of the network — it is a set of
//  promises. Every entry says "send me traffic for this destination and I
//  will deliver it", and a node that publishes a route it cannot carry
//  does not merely mislead: it attracts traffic and drops it, which is
//  worse for the network than never having spoken.
//
//  The guard used to be a single check that forwarding was switched on.
//  That was the right question while routes came from NODES broadcasts,
//  where a route is another node's own promise passed along. This station
//  has never received a broadcast (2026-08-27: zero PID-0xCF frames in
//  the retained window), so every route in its table is *inferred* —
//  assembled from overheard traffic. Publishing those unchanged announced
//  `KN6VV-1 via HORSE`, where HORSE is not a neighbour, has never carried
//  a packet for us, and could not be asked to.
//
//  So the test is not "do we believe this route" but "could we act on it
//  right now": is the next hop a station we are currently in touch with.
//  Everything else is a claim about somebody else's network.
//

import Foundation

nonisolated enum NetRomAdvertisableRoutes {

    /// How stale a route may be and still be promised.
    ///
    /// One BPQ NODESINTERVAL, doubled. A route heard four days ago — as
    /// EVANS was — describes a network that has had four days to change.
    static let maxRouteAge: TimeInterval = 2 * 60 * 60

    /// How recently the next hop must have been heard to count as
    /// somewhere we can still hand a packet to.
    static let maxNeighborSilence: TimeInterval = 45 * 60

    /// Ceiling on what an inferred route may claim.
    ///
    /// NET/ROM quality is meant to be comparable between nodes, and ours
    /// is a number from a different scale entirely — an EWMA of things we
    /// overheard. Publishing it raw enters this station into a comparison
    /// it has not earned. Capping it keeps AXTerm a last resort rather
    /// than a preferred path: usable if nothing better exists, never the
    /// route that displaces a node which actually carries traffic.
    static let inferredQualityCeiling = 64

    /// Routes safe to publish, and why the others were held back.
    struct Decision: Equatable {
        let advertisable: [RouteInfo]
        let withheld: [(destination: String, reason: String)]

        static func == (lhs: Decision, rhs: Decision) -> Bool {
            lhs.advertisable == rhs.advertisable
                && lhs.withheld.map(\.destination) == rhs.withheld.map(\.destination)
                && lhs.withheld.map(\.reason) == rhs.withheld.map(\.reason)
        }
    }

    /// Filter the route table down to promises this station can keep.
    static func decide(
        routes: [RouteInfo],
        neighbors: [NeighborInfo],
        now: Date
    ) -> Decision {
        var live: [String: NeighborInfo] = [:]
        for neighbor in neighbors
        where now.timeIntervalSince(neighbor.lastSeen) <= maxNeighborSilence {
            live[normalize(neighbor.call)] = neighbor
        }

        var advertisable: [RouteInfo] = []
        var withheld: [(destination: String, reason: String)] = []

        for route in routes {
            // Harvested routes are excluded outright, not merely quality-capped:
            // they were read out of another node's ROUTES table, and advertising
            // them would let one operator's scrape propagate through the network
            // as if it were that node's own broadcast. Second-hand knowledge is
            // not ours to promise at any quality.
            guard route.sourceType != "harvested" else {
                withheld.append((route.destination,
                                 "harvested from \(route.origin)'s table — second-hand knowledge is not ours to advertise"))
                continue
            }
            let hop = normalize(route.origin)
            guard let neighbor = live[hop] else {
                withheld.append((route.destination,
                                 "\(route.origin) is not a station we are in touch with"))
                continue
            }
            guard now.timeIntervalSince(route.lastUpdated) <= maxRouteAge else {
                withheld.append((route.destination, "last seen too long ago to promise"))
                continue
            }
            guard route.quality > 0 else {
                withheld.append((route.destination, "no measured quality"))
                continue
            }
            // Never better than the link we would carry it over: a route
            // cannot be more reliable than its own first hop.
            var quality = min(route.quality, neighbor.quality)
            if route.sourceType != "broadcast" {
                quality = min(quality, inferredQualityCeiling)
            }
            advertisable.append(RouteInfo(
                destination: route.destination,
                origin: route.origin,
                quality: quality,
                path: route.path,
                lastUpdated: route.lastUpdated,
                sourceType: route.sourceType))
        }
        return Decision(advertisable: advertisable, withheld: withheld)
    }

    private static func normalize(_ call: String) -> String {
        call.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
