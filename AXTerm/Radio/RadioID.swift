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
}
