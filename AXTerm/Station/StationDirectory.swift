import Foundation

/// The network's own directory: which stations run what.
///
/// `station_services` has been filling up since the service harvester landed
/// and nothing has ever shown it. That is a real loss — on a network where
/// nobody broadcasts NODES, an ID beacon saying `Node:KD0SSP-7; PBBS:KD0SSP-1`
/// is the only announcement of a service that will ever be made, and it goes
/// past in the terminal once.
///
/// The presentation rules live here rather than in the view so they can be
/// tested, and so both shells group and sort identically.
nonisolated enum StationDirectory {

    /// One station and everything it is known to run.
    struct Listing: Equatable, Identifiable, Sendable {
        var callsign: String
        /// Sorted strongest-claim first, then alphabetically by service.
        var entries: [StationServiceEntry]

        var id: String { callsign }

        /// The alias the station announced, if any — `DRLNOD` rather than
        /// `KB5YZB-7`. Operators name nodes by alias far more often than by
        /// callsign, so it belongs on the row.
        var alias: String? {
            entries.compactMap(\.alias).first
        }

        var lastHeard: Date? {
            entries.map(\.lastHeard).max()
        }

        /// True when nothing here is more than the station's own word.
        ///
        /// Worth surfacing: a declared BBS may be a station that once ran one,
        /// while a demonstrated digipeater repeated a frame we watched.
        var isEntirelyDeclared: Bool {
            !entries.isEmpty && entries.allSatisfy { $0.confidence == .declared }
        }
    }

    /// Groups entries into one listing per station.
    ///
    /// Sorted by callsign rather than by recency: a directory is something an
    /// operator scans for a name they half-remember, and a list that reorders
    /// itself as traffic arrives cannot be scanned at all.
    static func listings(from entries: [StationServiceEntry]) -> [Listing] {
        Dictionary(grouping: entries) { $0.callsign.uppercased() }
            .map { callsign, entries in
                Listing(callsign: callsign, entries: entries.sorted { lhs, rhs in
                    if lhs.confidence != rhs.confidence {
                        // Observed outranks declared: it is the stronger claim.
                        return lhs.confidence == .demonstrated
                    }
                    return lhs.service.rawValue < rhs.service.rawValue
                })
            }
            .sorted { $0.callsign < $1.callsign }
    }

    /// Narrows a directory by free text and by service.
    ///
    /// Text matches callsign, alias, and the service's own name, so typing
    /// "bbs" finds bulletin boards and typing "DRLNOD" finds the node that
    /// announced that alias.
    static func filter(_ listings: [Listing],
                       query: String,
                       service: StationServiceParser.Service?) -> [Listing] {
        let needle = query.trimmingCharacters(in: .whitespaces).uppercased()

        return listings.compactMap { listing -> Listing? in
            // Filtering by service narrows the *rows shown under a station*,
            // not merely which stations appear — showing a station's BBS
            // entry under a "digipeaters" filter would misreport what the
            // filter did.
            let entries = service.map { wanted in
                listing.entries.filter { $0.service == wanted }
            } ?? listing.entries
            guard !entries.isEmpty else { return nil }

            guard !needle.isEmpty else {
                return Listing(callsign: listing.callsign, entries: entries)
            }
            let haystack = [listing.callsign, listing.alias ?? ""]
                + entries.map { $0.service.label.uppercased() }
            guard haystack.contains(where: { $0.uppercased().contains(needle) }) else {
                return nil
            }
            return Listing(callsign: listing.callsign, entries: entries)
        }
    }

    /// Services present in a directory, for building a filter that only
    /// offers what is actually there.
    static func availableServices(in listings: [Listing]) -> [StationServiceParser.Service] {
        let present = Set(listings.flatMap { $0.entries.map(\.service) })
        return StationServiceParser.Service.allCases.filter(present.contains)
    }
}
