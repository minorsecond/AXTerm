//
//  HarvestedRoutePolicy.swift
//  AXTerm
//
//  Turns a scraped ROUTES row into a route the router may keep — or refuses.
//
//  Gate, then convert. The gate is the capability classifier: a KA-Node's
//  tables feed the alias directory for the prompt relay, never the NET/ROM
//  route table, because a KA-Node cannot open a NET/ROM circuit no matter
//  what its menu lists — DRLNOD's `N` output is a list of stations it has
//  *heard*, not a routing table. The gate is positive: "unknown" refuses
//  too, because second-hand routing knowledge needs a proven anchor.
//
//  Conversion is deliberately conservative. The anchor's quality figure is
//  its own opinion of its own link; we cap it before the router scales it by
//  OUR link to the anchor (broadcastRoutes' combinedQuality), so a harvested
//  route can never outrank what the network tells us about itself — and the
//  source tier (see NetRomRouter.sourceTier) keeps real broadcasts on top
//  even when the numbers tie.
//

import Foundation

nonisolated enum HarvestedRoutePolicy {

    static let sourceType = "harvested"

    /// Pre-scale ceiling on the anchor's claim. 192 is "good but never
    /// perfect": below the broadcast convention for a solid direct link,
    /// above the advertised-inferred ceiling, so the tiers stay visibly
    /// ordered even before tie-breaks.
    static let qualityCeiling = 192

    struct Decision: Equatable, Sendable {
        var accepted: [RouteInfo]
        /// Rows refused, with why — surfaced in breadcrumbs so a table that
        /// silently taught nothing is diagnosable.
        var refused: [Refusal]

        struct Refusal: Equatable, Sendable {
            var neighbor: String
            var reason: String
        }
    }

    static func decide(
        rows: [BpqRoutesScraper.HarvestedLink],
        anchorCanRouteNetRom: Bool?,
        localCallsign: String
    ) -> Decision {
        var decision = Decision(accepted: [], refused: [])
        let local = localCallsign.trimmingCharacters(in: .whitespaces).uppercased()

        for row in rows {
            guard anchorCanRouteNetRom == true else {
                let reason = anchorCanRouteNetRom == false
                    ? "\(row.anchor) is a KA-Node — its table cannot anchor NET/ROM routes"
                    : "\(row.anchor)'s node software is unproven — harvested routes need a positive verdict"
                decision.refused.append(.init(neighbor: row.neighbor, reason: reason))
                continue
            }
            guard row.neighbor != row.anchor else {
                decision.refused.append(.init(neighbor: row.neighbor, reason: "a node is not a route to itself"))
                continue
            }
            guard row.neighbor != local else {
                decision.refused.append(.init(neighbor: row.neighbor, reason: "that neighbor is this station"))
                continue
            }
            guard row.quality > 0 else {
                decision.refused.append(.init(neighbor: row.neighbor, reason: "the anchor itself measures the link at zero"))
                continue
            }
            decision.accepted.append(RouteInfo(
                destination: row.neighbor,
                origin: row.anchor,
                quality: min(row.quality, qualityCeiling),
                path: [row.anchor, row.neighbor],
                lastUpdated: row.observedAt,
                sourceType: sourceType
            ))
        }
        return decision
    }
}
