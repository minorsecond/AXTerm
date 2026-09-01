import SwiftUI

/// The profile's natural content height, published so whoever presents it
/// can fit the container to the content instead of picking a number.
nonisolated struct NodeProfileContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The width actually given to the profile, so the page can decide how many
/// columns fit rather than assuming a platform.
nonisolated struct NodeProfileContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The one identity view.
///
/// Presented as a sheet from a tapped callsign and as a pushed page from the
/// sheet, the Stations list and map callouts — same content either way, so an
/// operator learns one layout instead of four.
struct NodeProfileView: View {

    enum Presentation {
        /// A peek: compact, dismissible, with a way deeper in.
        case sheet
        /// The whole thing.
        case page
    }

    let profile: NodeProfile
    /// Needed to tell the two directions of the history apart.
    var localCallsign: String = ""
    /// Whether the operator has allowed directory lookups, so the empty
    /// state can give advice that matches their settings.
    var lookupEnabled: Bool = false
    /// True while a lookup for this callsign is in flight.
    var isLookingUp: Bool = false
    /// Where the operator's own notes live. Nil hides the section rather than
    /// showing an editor that cannot save.
    var noteStore: StationNoteStore?
    /// The ground between this station and ours, when terrain covering both
    /// ends has been downloaded. Computed by the caller — it needs the
    /// elevation store, our own position and both antenna heights, none of
    /// which this view has — and nil hides the section rather than showing an
    /// empty chart.
    var terrain: TerrainProfile?
    /// True when the far antenna height is the global assumption rather than
    /// one recorded for this station.
    var terrainHeightIsAssumed: Bool = false
    /// What the tiles this path needs would cost, when some are missing.
    var terrainEstimate: ElevationStorage.Estimate?
    /// When a connection to this station last completed over a path with no
    /// digipeater in it.
    var lastDirectConnection: Date?
    /// What the whole area around this station would cost.
    var terrainAreaEstimate: ElevationStorage.Estimate?
    /// False when no elevation source covers this path at all.
    var terrainSourceHasCoverage: Bool = true
    /// Set when the station is too far away for a terrain profile to mean
    /// anything, in kilometres.
    var terrainBeyondRadioRange: Double?
    var isDownloadingTerrain: Bool = false
    var onDownloadTerrain: (() -> Void)?
    var onDownloadTerrainArea: (() -> Void)?
    /// Mirrors the settings choice so a height typed on a station page reads
    /// back in the same unit everywhere else.
    @AppStorage(WinlinkSettings.heightUnitIsFeetKey) private var heightUnitIsFeet = true
    /// Same pattern for distances — the AppStorage mirror keeps the page
    /// in the operator's unit without threading a settings object in.
    @AppStorage(WinlinkSettings.distanceUnitIsMilesKey) private var distanceUnitIsMiles = true
    var presentation: Presentation = .page
    /// Offered only in the sheet, and only when there is somewhere to go.
    var onOpenFullPage: (() -> Void)?
    /// Nil disables the action rather than showing a dead button.
    var onConnect: (() -> Void)?
    var onShowOnMap: (() -> Void)?
    var onCompose: (() -> Void)?
    /// Opens another station's profile — cluster members and sibling SSIDs
    /// are questions, and a tap should answer them. Nil renders plain text.
    var onOpenCallsign: ((String) -> Void)?

    /// Forgets this station: its directory entry and every claim it made
    /// about other stations. Nil hides the action rather than showing a
    /// destructive button that does nothing.
    ///
    /// Needed because a misattribution cannot be undone by rule — once a
    /// station has been credited with another's words, nothing afterwards
    /// tells the bad claim from a good one, so the call is the operator's.
    var onForgetStation: (() -> Void)?

    @State private var confirmingForget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if profile.isServiceEndpoint {
                    serviceEndpoint
                } else if profile.isBare {
                    bare
                } else if presentation == .sheet {
                    // The peek the sheet was always meant to be: the headline
                    // numbers, what the station is, and the one warning that
                    // cannot wait. Every detail section lives on the full
                    // page — rendering them all here made the sheet a long
                    // scroll of things the tiles had already said.
                    statTiles
                    if !profile.roles.isEmpty { rolesSection }
                    if let topology = profile.topology, topology.isCritical {
                        criticalLine(topology)
                    }
                } else {
                    statTiles
                    // Balanced columns, not a grid: LazyVGrid makes every
                    // row as tall as its tallest cell, so a short Activity
                    // card next to a tall Roles card left a card-sized hole
                    // — enough of them and the page scrolled on a display
                    // with room to spare. Here each column stacks its cards
                    // independently, and cards are dealt to whichever column
                    // is currently shortest.
                    pageColumns
                }
                // Offered even for a bare callsign: knowing nothing about a
                // station is exactly when an operator most wants to write
                // down what they just learned. Never for a destination
                // address, which is not a thing to have notes about. On the
                // full page the editor rides in the columns with the other
                // cards instead of adding a full-width block underneath.
                if let noteStore, !profile.isServiceEndpoint, !notesLiveInColumns {
                    StationNotesSection(callsign: profile.callsign, store: noteStore,
                                        heightUnitIsFeet: $heightUnitIsFeet)
                }
                actions
                forgetSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Reports the content's natural size: height so the presenting
            // sheet can fit itself (grow until nothing needs scrolling, stop
            // at the window's edge), width so the page can pick its column
            // count from the space it actually got.
            .background(GeometryReader { proxy in
                Color.clear
                    .preference(key: NodeProfileContentHeightKey.self,
                                value: proxy.size.height)
                    .preference(key: NodeProfileContentWidthKey.self,
                                value: proxy.size.width)
            })
        }
        .onPreferenceChange(NodeProfileContentWidthKey.self) { width in
            measuredWidth = width
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                monogram
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(profile.callsign)
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .textSelection(.enabled)
                        if let alias = profile.alias {
                            Text(alias)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .foregroundStyle(.tint)
                                .background(.tint.opacity(0.12), in: Capsule())
                                .help("The NET/ROM alias this station answers to.")
                        }
                    }
                    if let subtitle = profile.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    // The prefix speaks when the directory has not: for a
                    // callsign with no licence record (most non-US calls —
                    // the directory covers few), where it is licensed is
                    // still printed in the callsign itself.
                    if profile.country == nil, !profile.isServiceEndpoint,
                       let region = CallsignRegion.region(for: profile.baseCallsign),
                       CallsignRegion.country(for: profile.baseCallsign)
                           != CallsignRegion.country(for: localCallsign) {
                        Text("Licensed in \(region), by callsign prefix")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let activity = profile.activity {
                        freshnessLine(activity)
                    }
                }
            }
            // Says which name led here, so an alias tap does not silently
            // become a different callsign.
            if let alias = profile.resolvedFromAlias {
                Label("Reached by tapping the alias \(alias)", systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !profile.reachVia.isEmpty {
                reachLine
            }
        }
    }

    /// The avatar: a quiet tinted disc carrying a glyph for what the station
    /// *is*. One accent colour, matching the alias chip and role icons — a
    /// first cut hashed the callsign into a hue, and a page of saturated
    /// party-balloon discs read as a toy, not a terminal. Grey for a
    /// destination address (not anyone) and for a station nothing is known
    /// about (no false vitality).
    private var monogram: some View {
        ZStack {
            Circle().fill(monogramIsMuted
                          ? AnyShapeStyle(.quaternary)
                          : AnyShapeStyle(.tint.opacity(0.12)))
            Image(systemName: monogramSymbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(monogramIsMuted
                                 ? AnyShapeStyle(.secondary)
                                 : AnyShapeStyle(.tint))
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }

    private var monogramIsMuted: Bool {
        profile.isServiceEndpoint || profile.isBare
    }

    private var monogramSymbol: String {
        if profile.isServiceEndpoint { return "signpost.right.and.left" }
        return profile.roles.first?.symbol ?? "antenna.radiowaves.left.and.right"
    }

    /// A live-ness dot beside how recently the station was heard. The
    /// thresholds match how the routing metrics think about recency: minutes
    /// mean "on the air now", a couple of hours means "around today".
    private func freshnessLine(_ activity: NodeProfile.Activity) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(freshnessColor(activity.lastHeard))
                .frame(width: 7, height: 7)
            Text(freshnessText(activity))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 1)
        .help(activity.lastHeard.map {
            "Last heard \($0.formatted(date: .abbreviated, time: .shortened))."
        } ?? "Never heard transmitting; known only from others' traffic.")
    }

    /// The topology warning, sheet-sized: the consequence in one line, with
    /// the full section left to the page.
    private func criticalLine(_ topology: NodeProfile.Topology) -> some View {
        Label {
            Text(criticalSummary(topology))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .help("Removing this station from the observed graph disconnects it. Details are on the full profile.")
    }

    private func freshnessColor(_ lastHeard: Date?) -> Color {
        guard let lastHeard else { return .gray.opacity(0.5) }
        let age = Date().timeIntervalSince(lastHeard)
        if age < 15 * 60 { return .green }
        if age < 2 * 3600 { return .yellow }
        return .gray
    }

    private func freshnessText(_ activity: NodeProfile.Activity) -> String {
        guard let last = activity.lastHeard else {
            return activity.heardCount == 0
                ? "Announced, never heard directly"
                : "\(activity.heardCount) frames heard"
        }
        return "Heard \(last.formatted(.relative(presentation: .named)))"
    }

    /// How to get there, as a picture: every station the connect will
    /// actually touch, in order. The old prose ("Connect to COSCO and ask
    /// for…") named only the teller; the operator then watched the app dial
    /// three other stations first and asked, reasonably, what it thought it
    /// was doing (2026-08-28).
    private var reachLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    pathNode("You", terminal: false)
                    ForEach(pathChain, id: \.self) { hop in
                        pathArrow
                        pathNode(hop, terminal: false)
                    }
                    pathArrow
                    pathNode(profile.alias ?? profile.callsign, terminal: true)
                }
            }
            if profile.reachVia.count > 1 {
                Text("Also listed by \(profile.reachVia.dropFirst().joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 3)
        .help("The connect walks this chain left to right: an AX.25 link to the "
              + "first node, then each node is asked at its own command prompt to "
              + "connect onward to the next. Built from the nodes' claims and this "
              + "station's route table — a plan, not a measured path.")
    }

    /// The chain the relay planner computed, falling back to the bare
    /// teller when planning had nothing more to say.
    private var pathChain: [String] {
        profile.plannedChain.isEmpty
            ? Array(profile.reachVia.prefix(1))
            : profile.plannedChain
    }

    private func pathNode(_ name: String, terminal: Bool) -> some View {
        Text(name)
            .font(.caption.monospaced().weight(terminal ? .semibold : .regular))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(terminal ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background(terminal
                        ? AnyShapeStyle(.tint.opacity(0.12))
                        : AnyShapeStyle(Color.primary.opacity(0.06)),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var pathArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    /// A destination, not a station.
    private var serviceEndpoint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not a station", systemImage: "signpost.right.and.left")
                .font(.headline)
            Text("\(profile.callsign) is a destination address, not a licensed station. Frames are sent *to* it — \(endpointPurpose) — and nobody answers a connect request there.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("That is why there is no licence record, no position and no link quality here: there is nothing to know, rather than nothing known yet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    /// What this particular destination is conventionally for.
    private var endpointPurpose: String {
        switch profile.baseCallsign.uppercased() {
        case "BEACON": return "unattended periodic transmissions announcing a station"
        case "ID": return "the identification a station is required to send"
        case "NODES": return "NET/ROM routing broadcasts"
        case "MAIL": return "mail notifications from a BBS"
        case "QST", "CQ", "ALL": return "a general call to anyone listening"
        case "WX": return "weather bulletins"
        case "TEST": return "test transmissions"
        default: return "a convention shared across the network"
        }
    }

    private var bare: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(isLookingUp ? "Looking it up\u{2026}" : "Nothing known yet")
                    .font(.headline)
                if isLookingUp { ProgressView().controlSize(.small) }
            }
            // The advice has to match the setting. Telling an operator to
            // enable a lookup they already enabled reads as the app not
            // knowing its own state.
            Text(bareExplanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var bareExplanation: String {
        if isLookingUp {
            return "Asking the callsign directory about \(profile.baseCallsign). Nothing has been heard from this station directly, so a licence record is all there is to find."
        }
        if lookupEnabled {
            return "This callsign has been seen on the air but nothing else is known. The directory had no record for \(profile.baseCallsign) \u{2014} unlicensed, unlisted, or a tactical alias \u{2014} and nothing has been heard from the station itself, only addressed to it."
        }
        return "This callsign has been seen on the air but nothing else about it is known \u{2014} no directory record, no position, and no routing history. Turning on callsign lookup in Settings would let AXTerm ask the directory who holds it."
    }

    // MARK: - Sections

    private var rolesSection: some View {
        section("Roles", systemImage: "person.badge.shield.checkmark") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(profile.roles, id: \.self) { role in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: role.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 26, height: 26)
                            .background(.tint.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(role.label).font(.subheadline.weight(.medium))
                            // Every role says what earned it — and for
                            // NET/ROM that is the station's own declaration,
                            // quoted rather than paraphrased.
                            Text(evidence(for: role))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Page columns

    /// The measured content width, driving the column count.
    @State private var measuredWidth: CGFloat = 0

    private var notesLiveInColumns: Bool {
        presentation == .page && !profile.isServiceEndpoint && !profile.isBare
            && noteStore != nil
    }

    private var columnCount: Int {
        guard measuredWidth > 0 else { return 2 }
        return max(1, min(3, Int(measuredWidth / 330)))
    }

    private var pageColumns: some View {
        let items = pageSectionItems
        let assignment = Self.distributeSections(estimates: items.map(\.estimate),
                                                 into: columnCount)
        return HStack(alignment: .top, spacing: 16) {
            ForEach(assignment.indices, id: \.self) { column in
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(assignment[column], id: \.self) { index in
                        items[index].view
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    /// Each card with a rough height estimate — enough to deal cards into
    /// columns of similar height without measuring anything. Estimates only
    /// steer balance; being off by half a card costs a little whitespace,
    /// never correctness.
    private var pageSectionItems: [(estimate: CGFloat, view: AnyView)] {
        var items: [(estimate: CGFloat, view: AnyView)] = []
        if !profile.roles.isEmpty {
            items.append((CGFloat(60 + profile.roles.count * 52), AnyView(rolesSection)))
        }
        if let activity = profile.activity,
           activity.lastHeard != nil || !activity.lastVia.isEmpty
            || activity.heardByHour.contains(where: { $0 > 0 }) {
            let chart: CGFloat = activity.heardByHour.contains(where: { $0 > 0 }) ? 80 : 0
            items.append((110 + chart, AnyView(activitySection(activity))))
        }
        if let placement = profile.placement {
            // A 150pt map, grid and coordinate rows, and two or three lines
            // saying what the coordinate is worth. The old estimate of 160
            // counted the map alone, so this card was dealt as the shortest
            // on the page while rendering as one of the tallest — and every
            // column it was not in ended a card early.
            items.append((330, AnyView(placementSection(placement))))
        }
        if let terrain {
            // Header, chart and legend. The chart carries a minHeight of its
            // own, so this is that plus the prose around it.
            items.append((260, AnyView(terrainSection(terrain))))
        }
        if !profile.links.isEmpty {
            // Each measured direction is a headline, bar, metric row,
            // sparkline with its caption, and a freshness line — the
            // tallest card on the page, and underestimating it stacked
            // Notes underneath and left a dead band below every other
            // column.
            items.append((CGFloat(60 + profile.links.count * 270), AnyView(linkSection)))
        }
        if let topology = profile.topology, !topology.isEmpty {
            let clusters = topology.communityMembers.isEmpty
                ? 0 : 70 + topology.communityMembers.count * 6
            items.append((CGFloat(100 + (topology.isCritical ? 60 : 0) + clusters),
                          AnyView(topologySection(topology))))
        }
        if !profile.siblings.isEmpty {
            items.append((CGFloat(110 + profile.siblings.count * 26), AnyView(siblingSection)))
        }
        if let netrom = profile.netrom {
            items.append((160, AnyView(netromSection(netrom))))
        }
        if let winlink = profile.winlink {
            items.append((180, AnyView(winlinkSection(winlink))))
        }
        if profile.name != nil || profile.licenseClass != nil {
            items.append((130, AnyView(licenceSection)))
        }
        if notesLiveInColumns, let noteStore {
            items.append((320, AnyView(
                StationNotesSection(callsign: profile.callsign, store: noteStore,
                                    heightUnitIsFeet: $heightUnitIsFeet))))
        }
        return items
    }

    /// Deals cards into columns of similar height: largest card first into
    /// the currently shortest column (longest-processing-time scheduling —
    /// placing in reading order let small cards fill the columns before the
    /// dominant Link-quality card arrived, which then towered over
    /// everything and left a dead band under the rest). Reading order is
    /// restored *within* each column afterwards, which is the order a
    /// reader actually experiences.
    nonisolated static func distributeSections(estimates: [CGFloat],
                                               into columns: Int) -> [[Int]] {
        let columnCount = max(1, columns)
        var assignment = Array(repeating: [Int](), count: columnCount)
        var heights = Array(repeating: CGFloat(0), count: columnCount)
        let bySize = estimates.indices.sorted {
            estimates[$0] != estimates[$1] ? estimates[$0] > estimates[$1] : $0 < $1
        }
        for index in bySize {
            let target = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            assignment[target].append(index)
            heights[target] += estimates[index]
        }
        return assignment.map { $0.sorted() }
    }

    // MARK: - Stat tiles

    private struct StatTile: Identifiable {
        let id: String
        let label: String
        let value: String
        let detail: String?
        let symbol: String
        let tint: Color
    }

    /// The numbers an operator scans for before reading anything: how much,
    /// how recently, how far, how good. Tiles rather than rows so the answer
    /// is legible at a glance; anything unknown simply has no tile.
    @ViewBuilder
    private var statTiles: some View {
        let tiles = tileData
        if tiles.count >= 2 {
            // Equal shares of the width, not `.adaptive(minimum:)`. Adaptive
            // fills the row with as many 100pt slots as fit and then leaves
            // the unused ones empty, so three tiles on a wide window sat in
            // the leftmost third under a band of nothing. There are at most
            // three of these.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                               count: tiles.count),
                spacing: 8) {
                ForEach(tiles) { statTile($0) }
            }
        }
    }

    private var tileData: [StatTile] {
        var tiles: [StatTile] = []
        if let activity = profile.activity, activity.heardCount > 0 {
            tiles.append(StatTile(id: "heard", label: "Heard",
                                  value: "\(activity.heardCount)", detail: "frames",
                                  symbol: "waveform", tint: .orange))
        }
        // No "last heard" tile: the freshness line in the header already
        // says it, two lines up, and saying it twice was the clutter.
        if let km = profile.placement?.distanceKilometres {
            let compass = profile.placement?.bearingDegrees
                .map { " \u{00B7} " + GreatCircle.compassPoint($0) } ?? ""
            tiles.append(StatTile(
                id: "distance", label: "Distance",
                value: DistanceDisplay.string(
                    kilometres: km, inMiles: distanceUnitIsMiles, format: "%.1f"),
                detail: DistanceDisplay.string(
                    kilometres: km, inMiles: !distanceUnitIsMiles) + compass,
                symbol: "location.north.line", tint: .purple))
        }
        if let quality = headlineQuality {
            tiles.append(StatTile(id: "quality", label: "Link quality",
                                  value: "\(quality)", detail: "of 255",
                                  symbol: "dot.radiowaves.left.and.right",
                                  tint: qualityTint(quality)))
        }
        return tiles
    }

    /// The best measured direction, falling back to NET/ROM's neighbour
    /// figure. "Best" rather than an average because the tile answers "can I
    /// work this station", and the better direction is the ceiling on that.
    private var headlineQuality: Int? {
        profile.links.map(\.quality).max() ?? profile.netrom?.neighbourQuality
    }

    private func statTile(_ tile: StatTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: tile.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tile.tint)
                Text(tile.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(tile.value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail = tile.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(platform: .platformCardBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func activitySection(_ activity: NodeProfile.Activity) -> some View {
        // Frame count and relative recency already lead the page as tiles;
        // this section carries what the tiles compress away — the exact
        // timestamp, the path the last frame took, and *when* this station
        // is on the air.
        section("Activity", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 8) {
                if let last = activity.lastHeard {
                    row("Last heard", last.formatted(date: .abbreviated, time: .shortened))
                }
                if !activity.lastVia.isEmpty {
                    row("Last path", activity.lastVia.joined(separator: " \u{2192} "))
                }
                if activity.heardByHour.contains(where: { $0 > 0 }) {
                    activityChart(activity.heardByHour)
                }
            }
        }
    }

    /// Frames heard per hour over the last day — one quiet single-hue bar
    /// row, because the question is magnitude over time ("when is this
    /// station actually on the air"), not identity. Hours with nothing get
    /// a hairline so silence is visibly measured rather than missing.
    private func activityChart(_ counts: [Int]) -> some View {
        let peak = max(counts.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Frames heard, last 24 hours")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(counts.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(counts[index] > 0
                              ? AnyShapeStyle(.tint)
                              : AnyShapeStyle(Color.primary.opacity(0.12)))
                        .frame(height: counts[index] > 0
                               ? max(4, 30 * CGFloat(counts[index]) / CGFloat(peak))
                               : 1.5)
                        .frame(maxWidth: .infinity)
                        .help(Self.hourBarHelp(index: index, count: counts[index],
                                               total: counts.count))
                }
            }
            .frame(height: 32, alignment: .bottom)
            HStack {
                Text("24 h ago").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("now").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    nonisolated static func hourBarHelp(index: Int, count: Int, total: Int) -> String {
        let from = total - index
        let to = from - 1
        let window = to == 0 ? "the last hour" : "\(from)\u{2013}\(to) h ago"
        return count == 0
            ? "Nothing heard \(window)."
            : "\(count) frame\(count == 1 ? "" : "s") heard \(window)."
    }

    /// Destructive, so it sits at the bottom, states exactly what goes, and
    /// asks first.
    @ViewBuilder
    private var forgetSection: some View {
        if let onForgetStation {
            VStack(alignment: .leading, spacing: 6) {
                Button(role: .destructive) {
                    confirmingForget = true
                } label: {
                    Label("Forget This Station\u{2026}", systemImage: "trash")
                }
                Text("Removes \(profile.callsign)'s directory entry and every claim it made "
                     + "about reaching other stations. Those other stations stay — only what "
                     + "this one said about them goes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .confirmationDialog("Forget \(profile.callsign)?",
                                isPresented: $confirmingForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { onForgetStation() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears what AXTerm learned about and from this station. "
                     + "It will be learned again if the station is heard.")
            }
        }
    }

    /// Why a path does or does not work, drawn.
    ///
    /// The verdict alone ("blocked by 180 m") is the answer; the picture is
    /// *where* and *what shape*, which is what decides whether a digipeater
    /// on a particular hill would help. A prediction, not a measurement —
    /// which is why it sits below the position rather than beside the
    /// heard-history that is evidence.
    @ViewBuilder
    private func terrainSection(_ terrain: TerrainProfile) -> some View {
        section("Terrain", systemImage: "mountain.2") {
            TerrainProfileView(profile: terrain,
                               originLabel: localCallsign.isEmpty ? "Here" : localCallsign,
                               destinationLabel: profile.callsign,
                               destinationHeightIsAssumed: terrainHeightIsAssumed,
                               estimate: terrainEstimate,
                               lastDirectConnection: lastDirectConnection,
                               areaEstimate: terrainAreaEstimate,
                               sourceHasCoverage: terrainSourceHasCoverage,
                               beyondRadioRange: terrainBeyondRadioRange,
                               isDownloading: isDownloadingTerrain,
                               onDownload: onDownloadTerrain,
                               onDownloadArea: onDownloadTerrainArea)
        }
    }

    private func placementSection(_ placement: NodeProfile.Placement) -> some View {
        section("Position", systemImage: "mappin.and.ellipse") {
            VStack(alignment: .leading, spacing: 6) {
                // A coordinate is a fact about a place, and a place is far
                // easier to judge on a map than as two decimals.
                NodeProfileMiniMap(
                    callsign: profile.callsign,
                    position: placement.position,
                    confidence: placement.confidence)
                // Distance and bearing are a tile at the top of the page;
                // this section carries what the tile cannot — where exactly.
                if let grid = placement.gridSquare { row("Grid", grid) }
                row("Coordinates", String(format: "%.4f, %.4f",
                                          placement.position.latitude,
                                          placement.position.longitude))
                // Precision and meaning are different questions; say which
                // one this coordinate answers.
                Text(confidenceNote(placement.confidence))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let source = placement.source {
                    Text("Source: \(source)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func confidenceNote(_ confidence: HeardStationMap.PositionConfidence) -> String {
        switch confidence {
        case .exact:
            return "An exact coordinate, consistent with everything else known about this station."
        case .gridSquare:
            return "The centre of a registered grid square — about 8 km across, so the pin describes the square rather than the antenna."
        case .inferredFromOperator:
            return "Inferred from the operator's licence address, not from the node itself. Nodes usually sit on a hilltop or repeater site rather than at the operator's house, so treat this as a lead."
        }
    }

    /// Both directions, side by side.
    ///
    /// The asymmetry is the finding. A station that hears us at 0.97 while we
    /// hear it at 0.40 has a receive problem, and one blended number would
    /// have read as a mediocre path and sent the operator looking at the
    /// wrong end.
    private var linkSection: some View {
        section("Link quality", systemImage: "arrow.left.arrow.right") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(profile.links) { link in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: link.isFromUs
                                  ? "arrow.up.right" : "arrow.down.left")
                                .font(.caption)
                                .foregroundStyle(link.isFromUs ? .blue : .green)
                            Text(link.isFromUs ? "Us to them" : "Them to us")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(link.quality) / 255")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        // A bar reads faster than a number for "is this good".
                        ProgressView(value: Double(link.quality), total: 255)
                            .tint(qualityTint(link.quality))

                        HStack(spacing: 14) {
                            if let df = link.df {
                                metric("df", String(format: "%.2f", df))
                            }
                            if let dr = link.dr {
                                metric("dr", String(format: "%.2f", dr))
                            }
                            if let etx = link.etx {
                                metric("ETX", String(format: "%.2f", etx))
                            }
                            if link.duplicates > 0 {
                                metric("dups", "\(link.duplicates)")
                            }
                        }
                        let samples = profile.history(fromUs: link.isFromUs,
                                                      localCallsign: localCallsign)
                        if samples.count >= 2 {
                            LinkQualitySparkline(samples: samples,
                                                 tint: qualityTint(link.quality))
                                .frame(height: 34)
                            HStack {
                                Text(historySpan(samples))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                if let trend = NodeProfile.trend(samples), abs(trend) >= 5 {
                                    Label(
                                        trend > 0 ? "up \(trend)" : "down \(abs(trend))",
                                        systemImage: trend > 0 ? "arrow.up.right" : "arrow.down.right")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(trend > 0 ? .green : .orange)
                                }
                            }
                        }

                        Text("Measured \(link.lastUpdated.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .explain(linkExplanation(link))
                }
                if profile.links.count == 1 {
                    Text("Only one direction has been measured. The other needs traffic that way before it can be.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func historySpan(_ samples: [LinkQualityHistorySample]) -> String {
        guard let first = samples.first?.sampledAt else { return "" }
        let span = Date().timeIntervalSince(first)
        return "\(samples.count) samples over \(WinlinkExchangeStatus.duration(Int(span)))"
    }

    private func evidence(for role: NodeProfile.Role) -> String {
        if role == .netromNode, let declaration = profile.netRomDeclaration {
            return declaration.evidence
        }
        if role == .kaNodeRelay, let fingerprint = profile.nodeSoftwareEvidence {
            return fingerprint
        }
        return role.evidence
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }

    private func qualityTint(_ quality: Int) -> Color {
        switch quality {
        case ..<64: return .red
        case ..<128: return .orange
        case ..<192: return .yellow
        default: return .green
        }
    }

    /// Says why the number is what it is, not what the letters stand for.
    private func linkExplanation(_ link: NodeProfile.DirectedLink) -> String {
        var lines: [String] = []
        lines.append(link.isFromUs
            ? "How well \(link.to) receives this station."
            : "How well this station receives \(link.from).")
        if let df = link.df, let dr = link.dr {
            lines.append(String(
                format: "df=%.2f is the share of frames that arrive; dr=%.2f is the share whose acknowledgement comes back.", df, dr))
            if let etx = link.etx {
                lines.append(String(
                    format: "ETX=%.2f follows from them: 1 / (df \u{00D7} dr), so about %.1f transmissions per delivered frame.", etx, etx))
            }
        } else {
            lines.append("Delivery probabilities are not known yet — they need frames in both directions to estimate.")
        }
        if link.duplicates > 0 {
            lines.append("\(link.duplicates) duplicate frame(s) seen, which usually means acknowledgements are being lost rather than data.")
        }
        lines.append("Quality \(link.quality)/255 is NET/ROM's own scale, and it is what routing decisions use.")
        return lines.joined(separator: " ")
    }

    /// The rest of the licence.
    /// Where this station sits in the shape of the network.
    ///
    /// Deliberately worded as consequences rather than graph theory. The
    /// operator does not need to know what an articulation point is; they
    /// need to know that if this station drops, four others go with it.
    private func topologySection(_ topology: NodeProfile.Topology) -> some View {
        section("In the Network", systemImage: "point.3.filled.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 8) {
                row("Direct links", "\(topology.neighbourCount)")
                    .help("Stations this one has been observed exchanging frames with, counting digipeated paths. Built from watched traffic, not from anything the station announced.")

                if topology.isCritical {
                    Label {
                        Text(criticalSummary(topology))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .help("Removing this station from the observed graph disconnects it into \(topology.partitionsWithoutIt.count) pieces of \(topology.partitionsWithoutIt.map(String.init).joined(separator: ", ")) stations. Nothing else that has been heard bridges those pieces \u{2014} which does not prove no other path exists, only that none has been observed.")
                }

                if !topology.communityMembers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Clusters with")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Chips, not a comma blob: each member is a question
                        // ("who is that?") and a tap answers it.
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96),
                                                     spacing: 6, alignment: .leading)],
                                  alignment: .leading, spacing: 6) {
                            ForEach(topology.communityMembers, id: \.self) { member in
                                callsignChip(member)
                            }
                        }
                    }
                    .help("These stations exchange more traffic with each other than with the rest of what has been heard, found by label propagation over the observed graph. On a network where nobody broadcasts NODES, this is what a \u{201C}local network\u{201D} actually looks like from the outside.")
                }
            }
        }
    }

    private func criticalSummary(_ topology: NodeProfile.Topology) -> String {
        let stranded = topology.strandedCount
        return "Everything heard so far reaches \(stranded) station\(stranded == 1 ? "" : "s") only through this one. If it goes off the air, they go with it."
    }

    private var siblingSection: some View {
        section("Other SSIDs", systemImage: "person.2") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(profile.siblings) { sibling in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        callsignChip(sibling.callsign)
                        if let role = sibling.roles.first {
                            Text(role.label)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        Spacer(minLength: 8)
                        // "0 heard" would be the same row as a station that
                        // has gone quiet. These have never transmitted at
                        // all — they are known only because their operator
                        // named them in a beacon.
                        Text(sibling.lastHeard == nil && sibling.heardCount == 0
                             ? "announced, not heard"
                             : "\(sibling.heardCount) heard")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Same licence, different service. An SSID is how one operator runs a node, a mailbox and a personal station on one callsign.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func netromSection(_ netrom: NodeProfile.NetRom) -> some View {
        section("NET/ROM", systemImage: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 6) {
                if let quality = netrom.neighbourQuality {
                    row("Neighbour quality", "\(quality) / 255")
                    // The same read-it-at-a-glance bar the link section uses,
                    // on the same 0–255 scale and colour thresholds.
                    ProgressView(value: Double(quality), total: 255)
                        .tint(qualityTint(quality))
                    // The table is built by watching traffic, so being in it
                    // says the station is nearby and audible — not that it
                    // runs NET/ROM.
                    Text(profile.netRomDeclaration == nil
                         ? "Measured from traffic heard directly, which is why it appears here. That is not a claim that this station runs NET/ROM — it has not said so."
                         : "Measured from traffic heard directly between this station and ours.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let via = netrom.reachedVia { row("Reached via", via) }
                if !netrom.routesVia.isEmpty {
                    row("Routes through it",
                        netrom.routesVia.prefix(8).joined(separator: ", ")
                        + (netrom.routesVia.count > 8 ? " +\(netrom.routesVia.count - 8) more" : ""))
                }
            }
        }
    }

    private func winlinkSection(_ quality: WinlinkLinkQuality) -> some View {
        section("Winlink", systemImage: "envelope.arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 6) {
                row("Sessions", "\(quality.completed) completed of \(quality.attempts) attempted")
                if let rate = quality.answerRate {
                    row("Answer rate", "\(Int((rate * 100).rounded()))%")
                }
                if let bps = quality.effectiveBytesPerSecond {
                    row("Throughput", String(format: "%.0f B/s", bps))
                }
                if let last = quality.lastAnsweredAt {
                    row("Last answered", last.formatted(date: .abbreviated, time: .shortened))
                }
                if let result = quality.lastResult { row("Last result", result) }
            }
        }
    }

    private var licenceSection: some View {
        section("Licence", systemImage: "person.text.rectangle") {
            VStack(alignment: .leading, spacing: 6) {
                if let name = profile.name { row("Name", name) }
                if let licenseClass = profile.licenseClass { row("Class", licenseClass) }
                let place = [profile.locality, profile.state, profile.country]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                if !place.isEmpty { row("Address", place.joined(separator: ", ")) }
                if let expires = profile.licenseExpires, !expires.isEmpty {
                    row("Expires", expires)
                }
                if let source = profile.directorySource {
                    Text("Looked up via \(source).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        // Nothing answers at a destination, so nothing is offered.
        if profile.isServiceEndpoint {
            EmptyView()
        } else {
            stationActions
        }
    }

    @ViewBuilder
    private var stationActions: some View {
        VStack(spacing: 8) {
            if let onConnect {
                Button {
                    onConnect()
                } label: {
                    // Named with the route rather than a bare "Connect". For a
                    // station nothing here has heard, the interesting part of
                    // the action is which node it goes through — the planned
                    // chain's first hop, the one this station actually dials,
                    // not the newest teller (which can sit *behind* the
                    // destination; field capture 2026-08-29 05:07).
                    Label((profile.plannedChain.first ?? profile.reachVia.first)
                              .map { "Connect via \($0)" } ?? "Connect",
                          systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help((profile.plannedChain.first ?? profile.reachVia.first).map {
                    "Connects to \($0), waits for its prompt, then asks it for "
                    + "\(profile.alias ?? profile.callsign)."
                } ?? "Opens an AX.25 connection to \(profile.callsign).")
            }
            HStack(spacing: 8) {
                if let onShowOnMap, profile.isPlaced {
                    Button {
                        onShowOnMap()
                    } label: {
                        Label("Show on Map", systemImage: "map")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                if let onCompose {
                    Button {
                        onCompose()
                    } label: {
                        Label("Message", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            // Offered only when the page has something the sheet does not.
            // A full-width bordered button with a trailing chevron also read as
            // a pop-up menu rather than a way onward, so it is a link now.
            if presentation == .sheet, profile.hasDepth, let onOpenFullPage {
                Button {
                    onOpenFullPage()
                } label: {
                    HStack(spacing: 3) {
                        Text("Full profile")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.callout)
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .help("Measurements, history and neighbours, with room to read them.")
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<Content: View>(_ title: String, systemImage: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Deliberately quiet: a tinted-square-per-section variant was
            // tried and a page of them read as a carnival. Colour in this
            // view is reserved for meaning — freshness, quality, warnings.
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(platform: .platformCardBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    /// A callsign as a small tappable chip. Quiet by design — identity is
    /// the text; the chip only says "this is a thing you can open".
    @ViewBuilder
    private func callsignChip(_ callsign: String) -> some View {
        let label = Text(callsign)
            .font(.caption.monospaced())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        if let onOpenCallsign {
            Button { onOpenCallsign(callsign) } label: { label }
                .buttonStyle(.plain)
                .help("Open \(callsign)'s profile.")
        } else {
            label
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
