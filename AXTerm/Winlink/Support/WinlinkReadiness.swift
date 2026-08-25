import Foundation

/// Pre-flight check for the station: everything an operator would
/// otherwise discover at the trailhead.
///
/// Nothing here is new capability — every fact is already knowable
/// somewhere in the app. The value is having them in one place, answered
/// before departure rather than found out afterwards. That is the whole
/// design principle: the failure mode in the field is not a missing
/// feature, it is a tired operator discovering a Keychain entry never
/// saved.
///
/// Evaluation is a pure function of a snapshot, so it is testable without
/// a radio, a database, or a network.
nonisolated struct WinlinkReadiness: Equatable, Sendable {

    enum Status: Int, Comparable, Sendable {
        /// Good to go.
        case ready
        /// Will work, but degraded or incomplete.
        case warning
        /// Cannot operate until fixed.
        case blocked

        static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }

        var symbolName: String {
            switch self {
            case .ready: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .blocked: "xmark.octagon.fill"
            }
        }
    }

    struct Check: Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        var status: Status
        /// What is actually true right now.
        var detail: String
        /// How to fix it. Nil when nothing needs fixing.
        var remedy: String?
    }

    /// A snapshot of everything the checks read. Assembled by the caller
    /// so this type touches no store, no Keychain, and no clock.
    struct Inputs: Equatable, Sendable {
        var callsign: String = ""
        var hasPassword: Bool = false
        var gatewayCount: Int = 0
        var gridSquare: String = ""
        var hasPositionFix: Bool = false
        var catalogItemCount: Int = 0
        var catalogFetchedAt: Date?
        var outageKitCount: Int = 0
        var outageKitBytes: Int = 0
        var p2pArmed: Bool = false
        var lastSuccessfulSessionAt: Date?
        var queuedOutboundCount: Int = 0
        var now: Date = Date()
    }

    var checks: [Check]

    /// The worst individual result — a station is only as ready as its
    /// weakest link.
    var overall: Status {
        checks.map(\.status).max() ?? .ready
    }

    var blockers: [Check] { checks.filter { $0.status == .blocked } }
    var warnings: [Check] { checks.filter { $0.status == .warning } }

    /// A catalog older than this is stale enough to mention. Gateways and
    /// products change slowly; a fortnight is generous.
    static let catalogStaleAfter: TimeInterval = 14 * 24 * 3600
    /// No successful session in this long means the path is unproven,
    /// whatever the settings say.
    static let sessionStaleAfter: TimeInterval = 30 * 24 * 3600

    static func evaluate(_ input: Inputs) -> WinlinkReadiness {
        WinlinkReadiness(checks: [
            callsignCheck(input),
            reachCheck(input),
            passwordCheck(input),
            positionCheck(input),
            catalogCheck(input),
            outageKitCheck(input),
            provenPathCheck(input),
            outboxCheck(input),
        ])
    }

    // MARK: - Individual checks

    private static func callsignCheck(_ input: Inputs) -> Check {
        let call = input.callsign.trimmingCharacters(in: .whitespaces).uppercased()
        // NOCALL is the placeholder the app falls back to; it is not a
        // licence and nothing will accept it.
        guard !call.isEmpty, call != "NOCALL" else {
            return Check(id: "callsign", title: "Callsign", status: .blocked,
                         detail: "Not set",
                         remedy: "Settings \u{2192} General. Nothing can be sent without it.")
        }
        return Check(id: "callsign", title: "Callsign", status: .ready, detail: call)
    }

    /// Something to talk to: a gateway ladder, or P2P armed. With
    /// neither, the station can compose mail and never move it.
    private static func reachCheck(_ input: Inputs) -> Check {
        switch (input.gatewayCount, input.p2pArmed) {
        case (0, false):
            return Check(id: "reach", title: "Someone to talk to", status: .blocked,
                         detail: "No gateways in the ladder, and P2P answering is off",
                         remedy: "Add a gateway in Stations, or arm P2P in Settings \u{2192} Winlink for grid-down operating.")
        case (0, true):
            return Check(id: "reach", title: "Someone to talk to", status: .warning,
                         detail: "P2P armed, but no gateway ladder",
                         remedy: "Fine for grid-down. Add a gateway if infrastructure is up.")
        case (let count, let armed):
            return Check(id: "reach", title: "Someone to talk to", status: .ready,
                         detail: "\(count) gateway\(count == 1 ? "" : "s")"
                             + (armed ? ", P2P armed" : ""))
        }
    }

    private static func passwordCheck(_ input: Inputs) -> Check {
        guard input.hasPassword else {
            return Check(id: "password", title: "Winlink password", status: .warning,
                         detail: "Not saved in the Keychain",
                         remedy: "Settings \u{2192} Winlink. CMS sessions will be refused without it; P2P does not need one.")
        }
        return Check(id: "password", title: "Winlink password", status: .ready,
                     detail: "Saved in the Keychain")
    }

    private static func positionCheck(_ input: Inputs) -> Check {
        if input.hasPositionFix {
            return Check(id: "position", title: "Position", status: .ready,
                         detail: "GPS fix available")
        }
        let grid = input.gridSquare.trimmingCharacters(in: .whitespaces)
        guard !grid.isEmpty, Maidenhead.isValid(grid) else {
            return Check(id: "position", title: "Position", status: .warning,
                         detail: grid.isEmpty ? "No grid square set" : "\(grid) is not a valid locator",
                         remedy: "Settings \u{2192} Winlink. Needed for the station list, position reports, and link-quality placement.")
        }
        // Four characters is 60 km of uncertainty — enough that link
        // measurements taken here will not count as "from here".
        if grid.count <= 4 {
            return Check(id: "position", title: "Position", status: .warning,
                         detail: "\(grid.uppercased()) \u{2014} 4-character grid, \u{00B1}60 km",
                         remedy: "Six characters (e.g. \(grid.uppercased())lr) lets measured link quality apply to your location.")
        }
        return Check(id: "position", title: "Position", status: .ready,
                     detail: grid.uppercased())
    }

    private static func catalogCheck(_ input: Inputs) -> Check {
        guard input.catalogItemCount > 0, let fetchedAt = input.catalogFetchedAt else {
            return Check(id: "catalog", title: "Catalog index", status: .warning,
                         detail: "Not cached",
                         remedy: "Request it by radio from the Catalog sheet \u{2014} it is the index of everything requestable.")
        }
        let age = input.now.timeIntervalSince(fetchedAt)
        let days = Int(age / 86400)
        if age > catalogStaleAfter {
            return Check(id: "catalog", title: "Catalog index", status: .warning,
                         detail: "\(input.catalogItemCount) products, \(days) days old",
                         remedy: "Refresh while a path exists.")
        }
        return Check(id: "catalog", title: "Catalog index", status: .ready,
                     detail: "\(input.catalogItemCount) products, \(days) day\(days == 1 ? "" : "s") old")
    }

    private static func outageKitCheck(_ input: Inputs) -> Check {
        guard input.outageKitCount > 0 else {
            return Check(id: "outageKit", title: "Outage kit", status: .warning,
                         detail: "Nothing identified to stage",
                         remedy: "Cache the catalog and set your state in Settings \u{2192} Winlink.")
        }
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(input.outageKitBytes), countStyle: .file)
        return Check(id: "outageKit", title: "Outage kit", status: .ready,
                     detail: "\(input.outageKitCount) products ready to request (\(size))")
    }

    /// Settings that have never completed a session are a plan, not a
    /// capability.
    private static func provenPathCheck(_ input: Inputs) -> Check {
        guard let last = input.lastSuccessfulSessionAt else {
            return Check(id: "provenPath", title: "Proven path", status: .warning,
                         detail: "No successful exchange on record",
                         remedy: "Run one now while it is cheap to fix. Settings that have never worked are a plan, not a capability.")
        }
        let age = input.now.timeIntervalSince(last)
        let days = Int(age / 86400)
        if age > sessionStaleAfter {
            return Check(id: "provenPath", title: "Proven path", status: .warning,
                         detail: "Last successful exchange \(days) days ago",
                         remedy: "Antennas come down and gateways go off the air. Re-prove it.")
        }
        return Check(id: "provenPath", title: "Proven path", status: .ready,
                     detail: days == 0 ? "Exchanged today" : "Last exchange \(days) day\(days == 1 ? "" : "s") ago")
    }

    private static func outboxCheck(_ input: Inputs) -> Check {
        guard input.queuedOutboundCount > 0 else {
            return Check(id: "outbox", title: "Outbox", status: .ready, detail: "Empty")
        }
        return Check(id: "outbox", title: "Outbox", status: .warning,
                     detail: "\(input.queuedOutboundCount) message\(input.queuedOutboundCount == 1 ? "" : "s") waiting to send",
                     remedy: "Run Connect & Exchange before you lose the path.")
    }
}
