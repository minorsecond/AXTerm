import Foundation

/// Picks the catalog products worth having on disk *before* the network
/// you would use to request them goes away.
///
/// The useful moment for this is always earlier than it feels. An ICS-205
/// frequency plan is exactly what an operator needs when infrastructure
/// is gone, and exactly what cannot be fetched once it is. So the kit is
/// deliberately biased toward small, durable, operationally load-bearing
/// documents rather than toward forecasts, which go stale in hours and
/// can be re-requested whenever a path exists.
///
/// Selection is **mechanical and explainable**: every product is included
/// by a stated rule, and `reason` says which one, so an operator can see
/// why a 6 kB net schedule made the list and a 161-product radar category
/// did not.
nonisolated enum WinlinkOutageKit {

    /// Why a product is in the kit. Ordered by how badly it is missed.
    enum Reason: String, CaseIterable, Sendable, Comparable {
        /// Frequency plans and net schedules — ICS-205s, P2P nets. These
        /// tell you where to find other stations with no infrastructure
        /// at all, and they are useless to request afterwards.
        case operatingPlan
        /// How the system itself works, including the P2P documentation.
        case reference
        /// Propagation basics: what the bands are likely to do.
        case propagation
        /// Forecasts for the operator's own state. Perishable, but the
        /// first thing anyone asks for.
        case localWeather

        var title: String {
            switch self {
            case .operatingPlan: "Operating plans & nets"
            case .reference: "System reference"
            case .propagation: "Propagation"
            case .localWeather: "Local weather"
            }
        }

        /// Sort order for display — most load-bearing first.
        private var rank: Int {
            switch self {
            case .operatingPlan: 0
            case .reference: 1
            case .propagation: 2
            case .localWeather: 3
            }
        }

        static func < (lhs: Reason, rhs: Reason) -> Bool { lhs.rank < rhs.rank }
    }

    struct Selection: Equatable, Sendable, Identifiable {
        var item: WinlinkCatalogItemRecord
        var reason: Reason
        var id: String { item.inquiryId }
    }

    /// Categories whose every product is an operating plan.
    private static let operatingPlanCategories: Set<String> = ["ARES_RACES", "HF_NETS"]

    /// Individually named reference products. Kept to a short list on
    /// purpose: `WL2K_HELP` holds 20 documents and staging all of them
    /// would cost more airtime than the plans that matter.
    private static let referenceIds: Set<String> = [
        "WL2K.DISC",     // service disclaimer — what the system does not promise
        "CUSTOM.GRIB",   // how to request data once a path exists again
        "WL2K.QTH",      // how to submit and request position reports
        // Who else is out there. With infrastructure gone this is the
        // nearest thing to a directory of stations reachable by P2P,
        // and it cannot be requested once the path is down.
        "WL2K_NEARBY",
    ]

    /// Propagation products small enough to be worth carrying.
    private static let propagationIds: Set<String> = [
        "PROP_WWV",      // daily solar flux, A & K — 482 bytes
    ]

    /// Builds the kit from the cached catalog.
    ///
    /// - Parameters:
    ///   - items: the catalog index as cached.
    ///   - state: the operator's USPS state code, for local forecasts.
    ///     Empty means no local weather is staged — better to stage
    ///     nothing than another state's forecasts.
    ///   - includeLocalWeather: forecasts are perishable; an operator
    ///     staging for a long outage may not want them.
    static func build(items: [WinlinkCatalogItemRecord],
                      state: String,
                      includeLocalWeather: Bool = true) -> [Selection] {
        var selections: [Selection] = []
        let stateCode = state.trimmingCharacters(in: .whitespaces).uppercased()
        let localCategory = stateCode.isEmpty ? nil : "WX_US_\(stateCode)"

        for item in items where item.enabled {
            let category = item.category.uppercased()
            let id = item.inquiryId.uppercased()

            if operatingPlanCategories.contains(category) {
                selections.append(Selection(item: item, reason: .operatingPlan))
            } else if referenceIds.contains(id) {
                selections.append(Selection(item: item, reason: .reference))
            } else if propagationIds.contains(id) {
                selections.append(Selection(item: item, reason: .propagation))
            } else if includeLocalWeather, let localCategory, category == localCategory {
                selections.append(Selection(item: item, reason: .localWeather))
            }
        }

        // Deterministic: same catalog in, same kit out, so two operators
        // staging from the same index queue the same request.
        return selections.sorted {
            ($0.reason, $0.item.inquiryId) < ($1.reason, $1.item.inquiryId)
        }
    }

    /// Total estimated response size for a kit.
    static func totalBytes(_ selections: [Selection]) -> Int {
        selections.reduce(0) { $0 + $1.item.sizeEstimate }
    }

    /// Groups a kit for display, in reason order.
    static func grouped(_ selections: [Selection]) -> [(reason: Reason, items: [Selection])] {
        Dictionary(grouping: selections, by: \.reason)
            .map { (reason: $0.key, items: $0.value) }
            .sorted { $0.reason < $1.reason }
    }
}
