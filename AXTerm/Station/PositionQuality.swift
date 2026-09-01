import Foundation

/// What a coordinate actually describes, and how far wrong it can be.
///
/// Every distance, bearing, coverage ring and terrain verdict in this app
/// starts from a position, and the positions come from sources that are not
/// remotely equally good. Until now they were all just `latitude` and
/// `longitude`, and a licence address printed to seven decimal places looked
/// exactly as authoritative as a surveyed antenna.
///
/// Measured on this operator's own directory of 166 stations: 143 carry seven
/// decimal places, which is centimetre precision, and three unrelated
/// callsigns share one coordinate to the last digit. That is a town or ZIP
/// centroid wearing a survey's clothes.
nonisolated enum PositionQuality {

    /// Where a coordinate came from, ordered by how well it describes the
    /// antenna rather than the person.
    enum Source: String, Equatable, Sendable, CaseIterable, Comparable {
        /// The operator standing under their own antenna.
        case surveyed
        /// This device's GPS. Exact for the device, correct only when the
        /// radio is with it.
        case deviceGPS
        /// A street address the operator typed, geocoded to a building.
        case geocodedAddress
        /// The station's own announced locator, from its beacon.
        case announcedLocator
        /// A licence address. May be a post office.
        case licenceAddress
        /// A Maidenhead square, coarse by construction and honest about it.
        case gridSquare

        /// Roughly how far the antenna can be from the coordinate.
        ///
        /// The grid figure is the half-diagonal of a six-character subsquare
        /// at mid latitudes, about 7 km by 4.6 km. The licence figure is a
        /// judgement: a ZIP centroid in a rural county can be far worse, and
        /// the number exists to stop the page implying metres.
        var accuracyMetres: Double {
            switch self {
            case .surveyed: return 10
            case .deviceGPS: return 20
            case .geocodedAddress: return 100
            case .announcedLocator: return 4_300
            case .licenceAddress: return 2_000
            case .gridSquare: return 4_300
            }
        }

        var label: String {
            switch self {
            case .surveyed: return "Surveyed"
            case .deviceGPS: return "This device"
            case .geocodedAddress: return "Address"
            case .announcedLocator: return "Announced locator"
            case .licenceAddress: return "Licence address"
            case .gridSquare: return "Grid centre"
            }
        }

        /// Better sources sort higher, so picking the best available is a
        /// `min` rather than a hand-written ladder at each call site.
        static func < (lhs: Source, rhs: Source) -> Bool {
            lhs.accuracyMetres < rhs.accuracyMetres
        }
    }

    /// Reasons a coordinate is worse than its source suggests.
    enum Doubt: Equatable, Sendable {
        /// The licence address is a post office box, so the coordinate is a
        /// post office.
        case postOfficeBox
        /// Other callsigns resolve to this exact coordinate, so it belongs to
        /// none of them. A ZIP or town centroid.
        case sharedWithOthers(count: Int)

        var warning: String {
            switch self {
            case .postOfficeBox:
                return "This is a PO box, so the position is a post office rather "
                    + "than an antenna."
            case .sharedWithOthers(let count):
                return "\(count) other station\(count == 1 ? "" : "s") resolve to this "
                    + "exact coordinate, so it is a town or postcode centre rather "
                    + "than any one antenna."
            }
        }
    }

    /// Whether a licence address line is a mailbox rather than a place.
    ///
    /// The street line is the only way to know. HamDB returns it and the app
    /// was discarding it, which is why a PO box was previously
    /// indistinguishable from a house.
    ///
    /// Deliberately narrow. "Box Canyon Road" and "Boxwood Lane" are streets,
    /// and a false positive throws away a usable position.
    static func isMailbox(_ address: String?) -> Bool {
        guard let address else { return false }
        let text = address.uppercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }

        // A leading box designator, or one after a unit prefix.
        for prefix in ["PO BOX", "P O BOX", "POBOX", "POST OFFICE BOX",
                       "PMB", "PRIVATE MAILBOX", "HC 1 BOX", "RR 1 BOX"] {
            if text.hasPrefix(prefix) { return true }
        }
        // "BOX 412" and "POB 55" on their own, but not "BOX CANYON RD".
        // The number is what separates a mailbox from a street named after
        // one, so it is required rather than assumed.
        for prefix in ["BOX ", "POB "] where text.hasPrefix(prefix) {
            let tail = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return tail.first?.isNumber == true
        }
        return false
    }

    /// Coordinates claimed by more than one callsign.
    ///
    /// Compared as printed rather than by distance: a shared centroid is the
    /// *same* number repeated, and a tolerance would also catch two operators
    /// who genuinely live on one street.
    static func sharedCoordinates(
        _ positions: [(callsign: String, latitude: Double, longitude: Double)]
    ) -> [String: Int] {
        var byPosition: [String: [String]] = [:]
        for entry in positions {
            let key = String(format: "%.6f,%.6f", entry.latitude, entry.longitude)
            byPosition[key, default: []].append(entry.callsign.uppercased())
        }
        var others: [String: Int] = [:]
        for (_, callsigns) in byPosition where callsigns.count > 1 {
            let unique = Set(callsigns)
            guard unique.count > 1 else { continue }
            for callsign in unique {
                others[callsign] = unique.count - 1
            }
        }
        return others
    }
}
