import Foundation

/// Space weather for one day, as measured rather than forecast.
///
/// Recorded for every day a session runs so it can be recalled later — and
/// so it is on disk when there is no internet to ask for it, which is the
/// day it is most likely to be wanted.
nonisolated struct SolarConditions: Equatable, Sendable, Codable {

    /// Midnight UTC of the day these describe.
    var day: Date
    /// 10.7 cm solar flux. The usual proxy for ionisation.
    var solarFlux: Double?
    /// Planetary K, the day's maximum. Kp is the number operators quote.
    var kIndex: Double?
    /// Where the numbers came from, kept so a stale or odd reading can be
    /// traced rather than argued with.
    var source: String
    var fetchedAt: Date

    /// The standard descriptions for Kp. Deliberately the conventional
    /// wording rather than an invented scale — an operator who knows what
    /// "unsettled" means should not have to learn AXTerm's synonym for it.
    static func geomagneticDescription(kIndex: Double?) -> String? {
        guard let k = kIndex else { return nil }
        switch k {
        case ..<1: return "quiet"
        case ..<4: return "unsettled"
        case ..<5: return "active"
        case ..<6: return "minor storm"
        case ..<7: return "moderate storm"
        case ..<8: return "strong storm"
        default: return "severe storm"
        }
    }
}

/// How much space weather bears on the path a session actually used.
///
/// This exists to stop the app blaming the sun for things the sun did not
/// do — and, equally, to stop it dismissing the sun for a session whose band
/// it does not know. Printing solar indices beside a poor session invites
/// exactly one conclusion; whether that conclusion is available depends on
/// the path, and sometimes the honest answer is that we cannot say.
///
/// No band is assumed anywhere. Relevance is derived from the frequency the
/// session recorded, "no radio path" comes from the transport rather than
/// from a missing frequency, and a missing frequency is its own answer.
nonisolated enum SolarBandRelevance {

    enum Relevance: Equatable, Sendable {
        /// The ionosphere is the path.
        case dominant
        /// Real, and the reason a band opens at all — but not every day.
        case significant
        /// Normally not the story; a disturbed field can still show up.
        case marginal
        /// Nothing meaningful to say about this band.
        case negligible
        /// The session went over the internet. There was no radio path.
        case noRadioPath
        /// It was on the air, but the frequency was not recorded — so there
        /// is no basis for a claim in either direction.
        case unknownBand
    }

    /// Transports that carry no radio path at all.
    private static let wiredTransports: Set<String> = ["telnet", "internet", "tcp"]

    static func relevance(frequencyHz: Int?, transport: String) -> Relevance {
        if wiredTransports.contains(transport.lowercased()) { return .noRadioPath }
        // An RF session with no frequency logged was still on the air.
        // Reading that as "unaffected" would quietly dismiss space weather
        // for sessions it may well have affected.
        guard let hz = frequencyHz else { return .unknownBand }
        let mhz = Double(hz) / 1_000_000
        switch mhz {
        case ..<30: return .dominant
        case ..<60: return .significant
        case ..<300: return .marginal
        default: return .negligible
        }
    }

    /// The band's common name, derived rather than assumed. Nil when there
    /// is no frequency to derive it from.
    static func bandName(frequencyHz: Int?) -> String? {
        guard let hz = frequencyHz else { return nil }
        let mhz = Double(hz) / 1_000_000
        switch mhz {
        case ..<30: return "HF"
        case ..<60: return "6 m"
        case ..<300: return "VHF"
        default: return "UHF"
        }
    }

    /// What to say alongside the indices, or nil when they speak for
    /// themselves.
    static func note(frequencyHz: Int?, transport: String, kIndex: Double?) -> String? {
        let band = bandName(frequencyHz: frequencyHz)
        switch relevance(frequencyHz: frequencyHz, transport: transport) {
        case .dominant:
            // On HF the numbers are the explanation; adding words would be
            // padding.
            return nil
        case .significant:
            return "On \(band ?? "this band") these numbers decide whether it is open at "
                 + "all, though most days it is closed regardless."
        case .marginal:
            if let k = kIndex, k >= 6 {
                return "A disturbed field like this can reach \(band ?? "VHF") — auroral "
                     + "absorption and aurora scatter are real up here. Even so, a local "
                     + "packet link is usually limited by noise, collisions and terrain "
                     + "rather than by the sun."
            }
            return "Solar conditions have little bearing on a local \(band ?? "VHF") link. "
                 + "If this session went badly, look first at local noise, a busy channel, "
                 + "or the path to the far station."
        case .negligible:
            return "Space weather has essentially no bearing on \(band ?? "this band")."
        case .noRadioPath:
            return "This exchange went over the internet, so there was no radio path for "
                 + "space weather to affect."
        case .unknownBand:
            // The correction that matters: silence here would read as
            // "unaffected", which is a claim we have no basis for.
            return "The frequency for this session was not recorded, so there is no way to "
                 + "say whether these conditions bore on it. The numbers are what the day "
                 + "looked like, not an explanation of this link."
        }
    }
}

/// Reading NOAA SWPC's published feeds.
///
/// Two feeds, two shapes: the flux series is an array of objects, the
/// planetary K product is a header row followed by arrays of strings. Both
/// are parsed strictly — a feed that changed shape must fail rather than
/// yield plausible zeros, because a fabricated calm field is worse than no
/// reading at all.
nonisolated enum SolarConditionsFeed {

    struct FluxPoint: Equatable, Sendable {
        let time: Date
        let flux: Double
    }

    struct KPoint: Equatable, Sendable {
        let time: Date
        let kIndex: Double
    }

    enum FeedError: Error, Equatable {
        case unexpectedShape
        case empty
    }

    static let fluxURL = URL(string: "https://services.swpc.noaa.gov/json/f107_cm_flux.json")!
    static let planetaryKURL = URL(
        string: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json")!

    static func parseFlux(_ data: Data) throws -> [FluxPoint] {
        struct Row: Decodable {
            let time_tag: String
            let flux: Double
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            throw FeedError.unexpectedShape
        }
        guard !rows.isEmpty else { throw FeedError.empty }
        return rows.compactMap { row in
            guard let time = isoFormatter.date(from: row.time_tag) else { return nil }
            return FluxPoint(time: time, flux: row.flux)
        }
    }

    static func parsePlanetaryK(_ data: Data) throws -> [KPoint] {
        guard let rows = try? JSONDecoder().decode([[String]].self, from: data),
              rows.count > 1 else {
            throw FeedError.unexpectedShape
        }
        // Row 0 names the columns; find Kp by name rather than position, so
        // a column being inserted upstream does not silently shift the
        // reading to some other quantity.
        let header = rows[0]
        guard let kColumn = header.firstIndex(where: { $0.caseInsensitiveCompare("Kp") == .orderedSame })
        else { throw FeedError.unexpectedShape }

        let points = rows.dropFirst().compactMap { row -> KPoint? in
            guard row.count > kColumn,
                  let k = Double(row[kColumn]),
                  let time = spaceSeparatedFormatter.date(from: row[0]) else { return nil }
            return KPoint(time: time, kIndex: k)
        }
        guard !points.isEmpty else { throw FeedError.empty }
        return points
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let spaceSeparatedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
