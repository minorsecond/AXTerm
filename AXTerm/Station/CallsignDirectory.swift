import Foundation

/// What any callsign directory can tell us about a station.
///
/// Deliberately the intersection of what sources actually provide, not
/// the union: every field is optional because no source guarantees all
/// of them, and a record that claims a field it does not have is worse
/// than one that admits the gap.
nonisolated struct CallsignRecord: Codable, Equatable, Sendable {

    /// Base callsign, SSID stripped and uppercased.
    var callsign: String
    var name: String?
    var gridSquare: String?
    var latitude: Double?
    var longitude: Double?
    var locality: String?
    var state: String?
    var country: String?
    var licenseClass: String?
    /// Expiry exactly as the source printed it — sources disagree on
    /// format, and reformatting invites parsing it wrongly.
    var expires: String?

    /// Which directory answered. Kept on the record so a stale or wrong
    /// entry can be traced to its source.
    var source: String
    var fetchedAt: Date

    /// Coordinates, preferring the source's own lat/lon and falling back
    /// to the centre of its grid square.
    var position: GreatCircle.Point? {
        if let latitude, let longitude {
            return GreatCircle.Point(latitude: latitude, longitude: longitude)
        }
        guard let gridSquare, let center = Maidenhead.center(of: gridSquare) else { return nil }
        return GreatCircle.Point(center)
    }

    /// True when the record carries nothing worth caching.
    var isEmpty: Bool {
        name == nil && gridSquare == nil && latitude == nil && locality == nil
    }
}

/// Normalising a callsign before it goes to a directory.
nonisolated enum CallsignQuery {

    /// Strips the SSID and uppercases.
    ///
    /// Directories index licences, and a licence has no SSID: `W0ARP-10`
    /// is the gateway, `W0ARP` is the licensee. Querying the former
    /// returns nothing, which looks exactly like "no such station".
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let hyphen = trimmed.firstIndex(of: "-") else { return trimmed }
        return String(trimmed[trimmed.startIndex..<hyphen])
    }

    /// A cheap sanity check so obvious non-callsigns never reach the
    /// network: at least one letter and one digit, 3–8 characters.
    /// Tactical aliases like `MAIL`, `BEACON` and `ID` fail this, which
    /// is the point — they are destinations, not licensees.
    static func isPlausible(_ raw: String) -> Bool {
        let call = normalize(raw)
        guard (3...8).contains(call.count) else { return false }
        guard call.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return call.contains(where: \.isNumber) && call.contains(where: \.isLetter)
    }
}

/// A source of callsign information.
///
/// The point of the protocol is that AXTerm never depends on one
/// service. HamDB today; QRZ, a local FCC extract, or a cached bundle
/// tomorrow — each is an implementation, and the chain below decides
/// which answers.
protocol CallsignDirectory: Sendable {
    /// Shown to the operator and stored on the record.
    var sourceName: String { get }
    /// False for anything that works offline, so callers can order the
    /// chain to try local sources first and skip the network entirely
    /// when there is none.
    var requiresNetwork: Bool { get }

    /// Returns nil when the directory simply has no entry — distinct
    /// from throwing, which means the lookup itself failed.
    func lookup(_ callsign: String) async throws -> CallsignRecord?
}

/// Tries directories in order and returns the first real answer.
///
/// Order is the caller's policy: put offline sources first and the chain
/// costs nothing when the network is gone; put an authoritative source
/// first and it wins when reachable. A source that *throws* does not
/// stop the chain — one service being down must not mask another that
/// works.
nonisolated struct CallsignDirectoryChain: CallsignDirectory {

    let directories: [any CallsignDirectory]
    var sourceName: String { "Chain" }
    var requiresNetwork: Bool { directories.allSatisfy(\.requiresNetwork) }

    /// Set false to skip every network source — the grid-down posture.
    var allowsNetwork: Bool = true

    init(_ directories: [any CallsignDirectory], allowsNetwork: Bool = true) {
        self.directories = directories
        self.allowsNetwork = allowsNetwork
    }

    func lookup(_ callsign: String) async throws -> CallsignRecord? {
        guard CallsignQuery.isPlausible(callsign) else { return nil }
        var lastError: Error?
        for directory in directories {
            if directory.requiresNetwork && !allowsNetwork { continue }
            do {
                if let record = try await directory.lookup(callsign), !record.isEmpty {
                    return record
                }
            } catch {
                lastError = error
                continue
            }
        }
        // Only surface an error if *nothing* answered; a partial outage
        // that another source covered is not the caller's problem.
        if let lastError { throw lastError }
        return nil
    }
}
