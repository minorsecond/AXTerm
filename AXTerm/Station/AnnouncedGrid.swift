import Foundation
import Combine

/// A Maidenhead locator a station announced about itself.
///
/// For most of the world there is no callsign directory to ask — HamDB
/// covers the FCC — but packet operators, Europeans especially, put their
/// locator in their own beacon text for exactly that reason:
/// `DB0XYZ ... JO62ql` is the station stating its own position over the
/// air. That statement also travels: an internet-linked node retransmits
/// distant stations' beacons onto the local channel, so an endpoint on
/// another continent can still hand over its locator here.
nonisolated enum BeaconLocatorParser {

    /// Keywords whose presence lets an ALL-CAPS six-character locator
    /// through. Without one, `JN58TD` is indistinguishable from a callsign
    /// (the shapes coincide), and refusing to guess beats mis-pinning a
    /// station at a coordinate spelled by someone's callsign.
    private static let contextKeywords = ["QTH", "LOC", "GRID", "LOCATOR", "SQUARE"]

    /// The first plausible locator in a beacon or ID text, uppercased,
    /// or nil. Four-character squares are always accepted (no callsign
    /// shares the shape); six-character ones need either the conventional
    /// lowercase subsquare (`DM79po`) or a context keyword in the text.
    static func locator(in text: String) -> String? {
        let hasKeyword = contextKeywords.contains {
            text.uppercased().contains($0)
        }
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for token in tokens {
            if let grid = asLocator(String(token), keywordPresent: hasKeyword) {
                return grid
            }
        }
        return nil
    }

    private static func asLocator(_ token: String, keywordPresent: Bool) -> String? {
        let characters = Array(token)
        guard characters.count == 4 || characters.count == 6 else { return nil }
        let field = characters[0...1]
        guard field.allSatisfy({ ("A"..."R").contains($0.uppercased()) && $0.isLetter }),
              characters[2].isNumber, characters[3].isNumber else { return nil }
        if characters.count == 4 {
            return Maidenhead.center(of: token) != nil ? token.uppercased() : nil
        }
        let subsquare = characters[4...5]
        guard subsquare.allSatisfy({ $0.isLetter && ("A"..."X").contains($0.uppercased()) })
        else { return nil }
        // The lowercase subsquare is the convention's own disambiguator.
        let conventional = subsquare.allSatisfy(\.isLowercase)
        guard conventional || keywordPresent else { return nil }
        return Maidenhead.center(of: token) != nil ? token.uppercased() : nil
    }
}

/// Locators harvested from beacons, per full callsign, persisted so a
/// station placed yesterday is still placed at launch.
@MainActor
final class AnnouncedGridStore: ObservableObject {

    struct Announcement: Codable, Equatable, Sendable {
        var grid: String
        var heardAt: Date
    }

    @Published private(set) var announcements: [String: Announcement] = [:]

    private static let defaultsKey = "station.announcedGrids"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: Announcement].self, from: data) {
            announcements = stored
        }
    }

    /// Grid per full callsign, the shape `HeardStationMap.entries` takes.
    var grids: [String: String] {
        announcements.mapValues(\.grid)
    }

    /// Reads locators out of unconnected text frames. Timestamps come from
    /// the packets themselves, so re-sweeping stored traffic is idempotent
    /// rather than a freshness forgery (the alias-replay lesson).
    func ingest(packets: [Packet]) {
        var changed = false
        for packet in packets {
            guard packet.frameType == .ui,
                  let text = packet.infoText,
                  CallsignValidator.isValidCallsign(packet.fromDisplay),
                  let grid = BeaconLocatorParser.locator(in: text) else { continue }
            let call = packet.fromDisplay.uppercased()
            let existing = announcements[call]
            if existing?.grid == grid, let heardAt = existing?.heardAt,
               heardAt >= packet.timestamp { continue }
            announcements[call] = Announcement(
                grid: grid,
                heardAt: max(existing?.heardAt ?? .distantPast, packet.timestamp))
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(announcements) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
