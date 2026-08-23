import Foundation

/// FBB System IDentifier (SID) parsing and formatting.
///
/// SIDs are exchanged at session start and advertise protocol features,
/// e.g. `[WL2K-5.0-B2FWIHJM$]` or `[BPQ-6.0.24-B1FWIHJM$]`. AXTerm only
/// speaks the B2F extension; a gateway whose SID lacks `B2F` must be
/// treated as unsupported rather than risking a corrupted B1 exchange.
nonisolated struct WinlinkSID: Equatable, Sendable {
    var product: String
    var version: String
    var features: String

    /// The SID AXTerm sends: B2F with basic FBB compatibility flags.
    static func axterm(version: String) -> WinlinkSID {
        WinlinkSID(product: "AXTerm", version: version, features: "B2FHM$")
    }

    var rendered: String {
        "[\(product)-\(version)-\(features)]"
    }

    /// True when the peer advertises the B2F binary forwarding protocol.
    var supportsB2F: Bool {
        features.uppercased().contains("B2F")
    }

    /// Parses a SID token like `[WL2K-5.0-B2FWIHJM$]`.
    ///
    /// Returns nil when the text is not a SID. Products may themselves
    /// contain hyphens in the wild, so the version is taken as the middle
    /// segment(s) and the features as the final hyphen-separated segment.
    static func parse(_ line: String) -> WinlinkSID? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 else { return nil }

        let inner = String(trimmed.dropFirst().dropLast())
        let segments = inner.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2 else { return nil }

        let product = segments[0]
        let features = segments[segments.count - 1]
        let version = segments.dropFirst().dropLast().joined(separator: "-")
        guard !product.isEmpty, !features.isEmpty else { return nil }
        return WinlinkSID(product: product, version: version, features: features)
    }

    /// True when a received line looks like any SID banner (used to spot
    /// the start of the handshake in a stream of banner/MOTD text).
    static func isSIDLine(_ line: String) -> Bool {
        parse(line) != nil
    }
}
