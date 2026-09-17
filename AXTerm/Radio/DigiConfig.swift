import Foundation

/// A radio's APRS digipeater settings. Off by default: a radio volunteers its
/// transmitter for other stations' traffic only when the operator turns this
/// on, and only on that radio's channel. Decoded defensively so it can grow.
nonisolated struct DigiConfig: Codable, Equatable, Sendable {
    var enabled: Bool = false
    /// Repeat a `WIDE1-1` fill-in hop (home/fill-in digi behaviour).
    var fillIn: Bool = true
    /// The largest remaining `WIDEn-N` hop count this digi will still repeat;
    /// 0 disables wide-area digipeating. Default 2 is a responsible fill-in +
    /// one-wide-hop digi that will not regenerate WIDE7-7 floods.
    var wideAreaMaxHops: Int = 2
    /// Extra aliases this digi answers to by explicit call (its own callsign
    /// is always included), e.g. a club alias like `DWARC`.
    var aliases: [String] = []
    /// A repeat of the same frame seen within this window is dropped, so the
    /// digi never loops or echoes.
    var dupeSeconds: Int = 30

    init(enabled: Bool = false,
         fillIn: Bool = true,
         wideAreaMaxHops: Int = 2,
         aliases: [String] = [],
         dupeSeconds: Int = 30) {
        self.enabled = enabled
        self.fillIn = fillIn
        self.wideAreaMaxHops = wideAreaMaxHops
        self.aliases = aliases
        self.dupeSeconds = dupeSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        fillIn = try c.decodeIfPresent(Bool.self, forKey: .fillIn) ?? true
        wideAreaMaxHops = try c.decodeIfPresent(Int.self, forKey: .wideAreaMaxHops) ?? 2
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        dupeSeconds = try c.decodeIfPresent(Int.self, forKey: .dupeSeconds) ?? 30
    }
}
