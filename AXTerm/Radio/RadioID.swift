import Foundation

/// A radio: one TNC port on one link, operating under its own callsign.
///
/// Opaque and stable. Not the host:port (a serial TNC has neither), not the
/// callsign (two radios may share one), not the list position (radios get
/// reordered). Minted once, kept in settings, and stamped on every packet the
/// radio hears, so history stays attributable after the radio is renamed or
/// its transport changes.
nonisolated struct RadioID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    /// A fresh identity for a radio being added.
    init() { rawValue = UUID().uuidString }

    /// The radio a station had before it had several.
    ///
    /// A constant rather than a minted UUID so every layer — the settings
    /// migration, the database migration that backfills old rows, and the
    /// session APIs whose callers predate radios — agrees on it without
    /// asking anyone first.
    static let primary = RadioID(rawValue: "radio-primary")

    /// The order tie-breaks use when two radios' evidence is otherwise equal
    /// (CLAUDE.md §9: deterministic tie-breaking): the primary radio first,
    /// then by identifier. The same tables always yield the same choice.
    static func deterministicOrder(_ a: RadioID, _ b: RadioID) -> Bool {
        if a == b { return false }
        if a == .primary { return true }
        if b == .primary { return false }
        return a.rawValue < b.rawValue
    }
}
