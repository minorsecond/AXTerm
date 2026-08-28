import Foundation

/// Everything the station knows about one identity on the air.
///
/// A callsign appears in a dozen places — a terminal line, a map pin, the
/// Stations table, a via path, a gateway ladder — and until now each place
/// showed the fragment it happened to hold. The operator had to carry the
/// rest in their head. This assembles the fragments once so every entry point
/// can show the same answer to "who is this?".
///
/// Deliberately a value type built from snapshots: it is a *reading*, taken at
/// a moment, not a live object. Nothing here writes back.
nonisolated struct NodeProfile: Equatable, Sendable {

    /// How a station told us it is a NET/ROM node.
    ///
    /// Appearing in the neighbour table is **not** one of these. That table is
    /// built by watching traffic — `observePacket` records any direct frame,
    /// and the "classic" versus "inferred" labels distinguish two inference
    /// paths, not declared versus guessed. Calling every neighbour a NET/ROM
    /// node put the label on ordinary stations that merely transmitted nearby.
    enum NetRomDeclaration: Equatable, Sendable {
        /// It originated a NET/ROM routing broadcast — PID 0xCF to NODES.
        /// Nothing but a node sends one.
        case nodesBroadcast
        /// Its ID or beacon announced a node alias, e.g. `Node:KD0SSP-7`.
        case aliasAnnouncement(String)
        /// Its session output carried a software fingerprint that proves a
        /// NET/ROM stack — e.g. BPQ's "Network Node Server" greeting. The
        /// detail quotes the line that earned it (see NodeCapability).
        case softwareFingerprint(family: NodeSoftwareFamily, detail: String)

        var evidence: String {
            switch self {
            case .nodesBroadcast:
                return "It sent a NET/ROM routing broadcast (PID 0xCF to NODES). Only a node does that, so this is the station's own declaration rather than an inference."
            case .aliasAnnouncement(let alias):
                return "Its identification announced the node alias \(alias), which is the station telling the network what it runs."
            case .softwareFingerprint(_, let detail):
                return detail
            }
        }
    }

    /// What this identity does on the network, inferred from observed traffic
    /// rather than declared anywhere.
    enum Role: String, Equatable, Sendable, CaseIterable {
        case ourStation
        case nodeAlias
        case netromNode
        case kaNodeRelay
        case digipeater
        case bulletinBoard
        case relay
        case winlinkGateway

        var label: String {
            switch self {
            case .ourStation: return "This station"
            case .nodeAlias: return "NET/ROM alias"
            case .netromNode: return "NET/ROM node"
            case .kaNodeRelay: return "KA-Node relay"
            case .digipeater: return "Digipeater"
            case .bulletinBoard: return "Bulletin board"
            case .relay: return "Relay"
            case .winlinkGateway: return "Winlink gateway"
            }
        }

        var symbol: String {
            switch self {
            case .ourStation: return "antenna.radiowaves.left.and.right"
            case .nodeAlias: return "tag"
            case .netromNode: return "point.3.connected.trianglepath.dotted"
            case .kaNodeRelay: return "arrow.left.arrow.right.circle"
            case .digipeater: return "arrow.triangle.2.circlepath"
            case .bulletinBoard: return "tray.full"
            case .relay: return "arrow.left.arrow.right"
            case .winlinkGateway: return "envelope.arrow.triangle.branch"
            }
        }

        /// Why the app believes this, in the operator's terms.
        var evidence: String {
            switch self {
            case .ourStation:
                return "This is the callsign this app transmits under."
            case .nodeAlias:
                return "Seen announced as a NET/ROM alias rather than heard as a station callsign."
            case .netromNode:
                // Overridden per profile by the declaration that earned it;
                // this is the fallback wording only.
                return "The station declared itself a NET/ROM node."
            case .kaNodeRelay:
                // Overridden per profile by the fingerprint that earned it;
                // this is the fallback wording only.
                return "Its command menu is a Kantronics KA-Node. It relays connections and digipeats, but cannot route NET/ROM."
            case .digipeater:
                return "Its callsign has been seen in the digipeater path of frames from other stations."
            case .bulletinBoard:
                return "It identified itself as running a bulletin board."
            case .relay:
                return "It identified itself as a relay."
            case .winlinkGateway:
                return "A Winlink session has been attempted or completed with it."
            }
        }
    }

    /// Where the identity is, and how much to trust it.
    struct Placement: Equatable, Sendable {
        var position: GreatCircle.Point
        var confidence: HeardStationMap.PositionConfidence
        var gridSquare: String?
        var source: String?
        /// Distance and bearing from the operator, when their own position
        /// is known. Kilometres, because that is the unit the rest of the
        /// station's geometry already speaks.
        var distanceKilometres: Double?
        var bearingDegrees: Double?
    }

    /// What has actually been heard.
    struct Activity: Equatable, Sendable {
        var heardCount: Int
        var lastHeard: Date?
        var lastVia: [String]
    }

    /// One measured direction of a link.
    ///
    /// Direction matters and is routinely asymmetric — a station can hear us
    /// perfectly while we barely hear it. Collapsing the two into one number
    /// is how an asymmetric link gets diagnosed as "bad path" instead of
    /// "bad receive".
    struct DirectedLink: Equatable, Sendable, Identifiable {
        var from: String
        var to: String
        var quality: Int
        var df: Double?
        var dr: Double?
        var duplicates: Int
        var lastUpdated: Date
        /// True when this station is the sender — us to them.
        var isFromUs: Bool

        var id: String { "\(from)>\(to)" }

        /// Expected transmissions, per the routing-metrics spec.
        ///
        /// `ETX = 1 / (max(df,0.05) * max(dr,0.05))`, clamped to [1, 20]. The
        /// floor keeps a single bad sample from producing an infinity that
        /// then dominates every comparison.
        var etx: Double? {
            guard let df, let dr else { return nil }
            let value = 1.0 / (max(df, 0.05) * max(dr, 0.05))
            return min(max(value, 1.0), 20.0)
        }
    }

    /// Another SSID under the same licence.
    ///
    /// `K0NTS-1`, `-7` and `-10` are one operator running three services, and
    /// an operator looking at a node wants to know the mailbox next door
    /// exists.
    struct Sibling: Equatable, Sendable, Identifiable {
        var callsign: String
        var ssid: Int?
        var heardCount: Int
        var lastHeard: Date?
        var roles: [Role]
        var id: String { callsign }
    }

    /// The NET/ROM view of this identity.
    struct NetRom: Equatable, Sendable {
        /// 0–255 as NET/ROM reports it.
        var neighbourQuality: Int?
        /// Destinations reachable *through* this node.
        var routesVia: [String] = []
        /// How this node is reached, when it is not a direct neighbour.
        var reachedVia: String?
    }

    var callsign: String
    var baseCallsign: String
    var ssid: Int?
    /// A NET/ROM alias this callsign answers to (`DRLNOD`).
    var alias: String?
    /// Nodes that have listed this station, freshest first.
    ///
    /// The only actionable thing a harvested entry carries: the node that named
    /// a station is the node to connect through to reach it. Absent from the
    /// profile at first, which left the sheet showing a station it had nothing
    /// to say about while the one useful fact sat on the row behind it.
    var reachVia: [String] = []
    /// Set when the operator tapped an *alias* and this is the station behind it.
    var resolvedFromAlias: String?

    var name: String?
    var locality: String?
    var state: String?
    var country: String?
    var licenseClass: String?
    /// Which directory answered, so a stale or guessed record is attributable.
    var directorySource: String?

    var placement: Placement?
    var activity: Activity?
    var roles: [Role] = []
    var netrom: NetRom?
    /// Present only when the station said so itself.
    var netRomDeclaration: NetRomDeclaration?
    /// Software family proven by fingerprints (see NodeCapability). Matters
    /// most when negative: a KA-Node verdict means "cannot route NET/ROM"
    /// no matter what its ID beacon declares.
    var nodeSoftware: NodeSoftwareFamily?
    /// The prose behind that verdict, quoting the observed line.
    var nodeSoftwareEvidence: String?
    /// Services this station announced in an ID or beacon.
    var declaredServices: [StationServiceParser.Declaration] = []
    var winlink: WinlinkLinkQuality?
    /// Measured links touching this station, both directions where known.
    var links: [DirectedLink] = []
    /// How those links have behaved over time, oldest first.
    ///
    /// Separate from `links` because it answers a different question: `links`
    /// says what the path is like, this says whether it has changed.
    var linkHistory: [LinkQualityHistorySample] = []
    /// Other SSIDs on the same base callsign.
    var siblings: [Sibling] = []
    /// This station's place in the observed network graph.
    var topology: Topology?

    var isPlaced: Bool { placement != nil }

    /// True when this name is a destination, not a station.
    ///
    /// `BEACON`, `ID`, `NODES`, `QST`, `WIDE1-1` and the rest are addresses
    /// frames are sent *to*. Nobody holds a licence for them, no directory
    /// will ever have a record, and nothing answers a connect request at one
    /// — so the page must not offer Connect, and "nothing known yet" is the
    /// wrong story: there is nothing to know.
    var isServiceEndpoint: Bool {
        CallsignValidator.isServiceEndpoint(callsign)
    }

    /// The line under the title: the licensee if known, else what little is.
    var subtitle: String? {
        if let name, !name.isEmpty {
            if let locality, !locality.isEmpty { return "\(name) \u{00B7} \(locality)" }
            return name
        }
        if let locality, !locality.isEmpty { return locality }
        if let alias { return "Also announced as \(alias)" }
        return nil
    }

    /// Whether the full page would show anything the sheet does not already.
    ///
    /// The sheet is a peek — tiles, roles, one warning — and every detail
    /// section renders on the page only. So anything that produces a detail
    /// section counts as depth, licence records included: the sheet's
    /// subtitle shows the name, but the class and full address live in the
    /// Licence section, and without this the link to reach them never
    /// appeared for a directory-only station.
    var hasDepth: Bool {
        placement != nil || activity != nil || netrom != nil || winlink != nil
            || topology != nil || !links.isEmpty || !siblings.isEmpty
            || !linkHistory.isEmpty || !declaredServices.isEmpty
            || name != nil || licenseClass != nil
    }

    /// True when nothing beyond the callsign itself is known.
    ///
    /// Worth naming: a profile with no facts should say so plainly rather
    /// than render a page of empty rows.
    var isBare: Bool {
        name == nil && placement == nil && activity == nil
            && netrom == nil && winlink == nil && roles.isEmpty
            && links.isEmpty && siblings.isEmpty && linkHistory.isEmpty
            && declaredServices.isEmpty && reachVia.isEmpty
    }

    /// History for one direction, oldest first.
    func history(fromUs: Bool, localCallsign: String) -> [LinkQualityHistorySample] {
        let me = localCallsign.trimmingCharacters(in: .whitespaces).uppercased()
        return linkHistory.filter {
            fromUs ? $0.fromCall.uppercased() == me : $0.toCall.uppercased() == me
        }
    }

    /// Whether a direction has moved enough to be worth remarking on.
    ///
    /// Compares the mean of the oldest third against the newest third, which
    /// is steadier than first-versus-last on a metric that jitters. Nil when
    /// there is not enough history to say anything honest.
    static func trend(_ samples: [LinkQualityHistorySample]) -> Int? {
        guard samples.count >= 6 else { return nil }
        let third = max(1, samples.count / 3)
        let oldest = samples.prefix(third).map(\.quality)
        let newest = samples.suffix(third).map(\.quality)
        let before = Double(oldest.reduce(0, +)) / Double(oldest.count)
        let after = Double(newest.reduce(0, +)) / Double(newest.count)
        return Int((after - before).rounded())
    }

    /// The link from us to them, when it has been measured.
    var outboundLink: DirectedLink? { links.first { $0.isFromUs } }
    /// The link from them to us.
    var inboundLink: DirectedLink? { links.first { !$0.isFromUs } }

    // MARK: - Assembly

    /// Builds a profile from whatever each source happens to hold.
    ///
    /// Every input is optional because every one of them genuinely can be
    /// absent — a callsign heard once has no directory record, no position and
    /// no routing history, and that is a normal profile rather than an error.
    /// Where this station sits in the shape of the network.
    ///
    /// Two findings that no single station's record can contain, because both
    /// are properties of the graph rather than of the station: whether losing
    /// it would split the network, and which stations it clusters with.
    struct Topology: Equatable, Sendable {
        /// Stations this one is directly linked to in the observed graph.
        var neighbourCount: Int = 0
        /// Sizes of the pieces the network falls into without this station,
        /// largest first. Empty means removing it splits nothing.
        ///
        /// The sizes are the finding. "Articulation point" is jargon;
        /// "without this station, four stations are cut off from the other
        /// eleven" is something an operator can act on.
        var partitionsWithoutIt: [Int] = []
        /// Other stations in the same cluster, excluding this one.
        var communityMembers: [String] = []

        var isCritical: Bool { partitionsWithoutIt.count > 1 }

        /// How many stations get cut off — everything outside the largest
        /// remaining piece.
        var strandedCount: Int {
            guard isCritical else { return 0 }
            return partitionsWithoutIt.dropFirst().reduce(0, +)
        }

        var isEmpty: Bool {
            neighbourCount == 0 && communityMembers.isEmpty
        }
    }

    static func make(
        callsign rawCallsign: String,
        localCallsign: String = "",
        aliasDirectory: NodeAliasDirectory? = nil,
        heard: HeardStationMap.Entry? = nil,
        directory: CallsignRecord? = nil,
        neighbourQuality: Int? = nil,
        routesVia: [String] = [],
        reachedVia: String? = nil,
        netRomDeclaration: NetRomDeclaration? = nil,
        digipeaterCallsigns: Set<String> = [],
        declaredServices: [StationServiceParser.Declaration] = [],
        winlink: WinlinkLinkQuality? = nil,
        links: [DirectedLink] = [],
        linkHistory: [LinkQualityHistorySample] = [],
        siblings: [Sibling] = [],
        topology: Topology? = nil,
        observer: GreatCircle.Point? = nil,
        nodeSoftware: NodeSoftwareFamily? = nil,
        nodeSoftwareEvidence: String? = nil
    ) -> NodeProfile {

        let trimmed = rawCallsign.trimmingCharacters(in: .whitespaces).uppercased()

        // The operator may have tapped an alias. Resolve it, but remember that
        // they tapped the alias — the page should say which name led here.
        var resolvedFromAlias: String?
        var effective = trimmed
        if let aliasDirectory, let behind = aliasDirectory.callsign(for: trimmed) {
            resolvedFromAlias = trimmed
            effective = behind.uppercased()
        }

        let (base, ssid) = CallsignNormalizer.parse(effective)

        var profile = NodeProfile(
            callsign: effective,
            baseCallsign: base.uppercased(),
            ssid: ssid == 0 && !effective.contains("-") ? nil : ssid,
            alias: aliasFor(effective, in: aliasDirectory),
            reachVia: aliasDirectory?.tellers(forCallsign: effective) ?? [],
            resolvedFromAlias: resolvedFromAlias)

        // Licence details. The heard entry may already carry a name from an
        // earlier lookup, so it is the fallback rather than the loser.
        profile.name = directory?.name ?? heard?.name
        profile.locality = directory?.locality ?? heard?.locality
        profile.state = directory?.state
        profile.country = directory?.country
        profile.licenseClass = directory?.licenseClass
        profile.directorySource = directory?.source

        if let heard {
            profile.activity = Activity(
                heardCount: heard.heardCount,
                lastHeard: heard.lastHeard,
                lastVia: heard.lastVia)
        }

        // Position: prefer whatever placed the station on the map, because
        // that is the position the operator has already seen.
        if let point = heard?.position ?? directory?.position {
            var placement = Placement(
                position: point,
                confidence: heard?.confidence ?? .gridSquare,
                gridSquare: heard?.gridSquare ?? directory?.gridSquare,
                source: heard?.positionSource ?? directory?.source)
            if let observer {
                placement.distanceKilometres = GreatCircle.kilometres(from: observer, to: point)
                placement.bearingDegrees = GreatCircle.bearingDegrees(from: observer, to: point)
            }
            profile.placement = placement
        }

        if neighbourQuality != nil || !routesVia.isEmpty || reachedVia != nil {
            profile.netrom = NetRom(
                neighbourQuality: neighbourQuality,
                routesVia: routesVia.sorted(),
                reachedVia: reachedVia)
        }

        profile.winlink = winlink
        // Ours first: "can they hear me" is the question that decides whether
        // to call, and it is the direction an operator can act on.
        profile.links = links.sorted { lhs, rhs in
            if lhs.isFromUs != rhs.isFromUs { return lhs.isFromUs }
            return lhs.lastUpdated > rhs.lastUpdated
        }
        profile.linkHistory = linkHistory.sorted { $0.sampledAt < $1.sampledAt }
        profile.siblings = siblings
            .filter { $0.callsign.uppercased() != effective }
            .sorted { ($0.ssid ?? -1) < ($1.ssid ?? -1) }
        profile.topology = topology
        profile.netRomDeclaration = netRomDeclaration
        profile.nodeSoftware = nodeSoftware
        profile.nodeSoftwareEvidence = nodeSoftwareEvidence
        profile.declaredServices = declaredServices.filter {
            $0.callsign.uppercased() == effective
        }
        profile.roles = inferRoles(
            callsign: effective,
            localCallsign: localCallsign,
            heard: heard,
            isAlias: resolvedFromAlias != nil,
            netRomDeclaration: netRomDeclaration,
            digipeaterCallsigns: digipeaterCallsigns,
            declaredServices: profile.declaredServices,
            winlink: winlink,
            nodeSoftware: nodeSoftware)
        return profile
    }

    private static func aliasFor(_ callsign: String,
                                 in directory: NodeAliasDirectory?) -> String? {
        // Was a linear scan taking the first match in alias order, which for a
        // station running several services returned whichever name sorted
        // earliest — KE0NCQ came back as DRL, its digipeater, rather than
        // DRLNOD, the node the operator actually connects through.
        directory?.preferredAlias(for: callsign)
    }

    /// Roles are evidence, not configuration — each one has to be earned by
    /// something the station actually observed.
    static func inferRoles(
        callsign: String,
        localCallsign: String,
        heard: HeardStationMap.Entry?,
        isAlias: Bool,
        netRomDeclaration: NetRomDeclaration?,
        digipeaterCallsigns: Set<String>,
        declaredServices: [StationServiceParser.Declaration] = [],
        winlink: WinlinkLinkQuality?,
        nodeSoftware: NodeSoftwareFamily? = nil
    ) -> [Role] {
        var roles: [Role] = []
        let upper = callsign.uppercased()

        if !localCallsign.isEmpty,
           localCallsign.trimmingCharacters(in: .whitespaces).uppercased() == upper {
            roles.append(.ourStation)
        }
        if isAlias || heard?.isNodeAlias == true {
            roles.append(.nodeAlias)
        }
        // Only on the station's own word. Neighbour-table membership is an
        // observation about traffic, not a claim about what the station is.
        // A KA-Node fingerprint overrides both paths in: DRLNOD's ID beacon
        // declares `/N`, and it is still a KA-Node — the observed menu is
        // the stronger evidence, and "NET/ROM node" on a station that
        // cannot route NET/ROM is exactly the label this view exists to
        // stop applying.
        let declared = Set(declaredServices.map(\.service))
        if nodeSoftware == .kaNode {
            roles.append(.kaNodeRelay)
        } else if netRomDeclaration != nil || declared.contains(.node) {
            roles.append(.netromNode)
        }
        if declared.contains(.bbs) {
            roles.append(.bulletinBoard)
        }
        // Declared, or demonstrated by actually repeating someone's frame.
        // Both are evidence; the declaration is the stronger of the two.
        if declared.contains(.digipeater) || digipeaterCallsigns.contains(upper) {
            roles.append(.digipeater)
        }
        if declared.contains(.relay) {
            roles.append(.relay)
        }
        if winlink != nil {
            roles.append(.winlinkGateway)
        }
        return roles
    }
}
