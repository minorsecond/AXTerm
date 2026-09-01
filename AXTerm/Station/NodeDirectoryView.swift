//
//  NodeDirectoryView.swift
//  AXTerm
//
//  Every node alias this station has learned, in one browsable list.
//
//  The alias directory was doing real work long before it had a page: 179
//  aliases resolved behind the map, the node profiles and the via-path
//  labels. But nothing showed them, so from the operator's chair the
//  harvesting looked like it was not happening at all — the question
//  "are we saving these?" was asked three times, and the honest answer
//  each time was "yes, and you cannot see any of it" (2026-08-27).
//
//  Deliberately separate from Routes. A route is evidence that *this*
//  station can reach a destination, earned from traffic it observed. An
//  alias is hearsay: a name a node published, usually about somebody
//  else. Mixing them would put destinations in the routing table that
//  nothing here has ever reached — so they are neighbours in the sidebar
//  and nothing more.
//

import SwiftUI

struct NodeDirectoryView: View {
    @ObservedObject var aliases: NodeAliasStore

    /// Search text, owned by the shell.
    @Binding var query: String

    /// Restricts the page to one node's table. Set when the sidebar sends the
    /// operator here from a "Reachable via" row.
    ///
    /// Deliberately not the search field, which was how the sidebar used to
    /// do it. Searching a node's name matches every entry that *mentions* it
    /// anywhere in its teller list, and each match is then filed under
    /// whichever node listed it most recently — so clicking "KB5YZB-7 · 88"
    /// landed on a page headed "Via COSCO · 87", because COSCO had announced
    /// the same stations more recently. A route the operator asked for has to
    /// be a filter in its own right, or the page cannot honour it.
    @Binding var routeFilter: String?

    /// Opens the station behind a row. Nil leaves the list read-only.
    var onSelect: ((String) -> Void)?

    /// Connects to an alias through the given node. Nil hides the action.
    var onConnect: ((String, String) -> Void)?

    /// Every callsign this station knows of, from any source. Entries that
    /// offer no route *and* name none of these can be forgotten.
    var knownCallsigns: Set<String> = []

    /// The operator's own callsign, so rows licensed elsewhere can say so.
    /// Domestic entries stay untagged — on a US channel, "United States"
    /// four hundred times over is noise, and the foreign tag is the signal.
    var localCallsign: String = ""

    @State private var confirmingForget = false
    /// Row whose evidence popover is open.
    @State private var evidenceAlias: String?
    /// Entry awaiting "forget?" confirmation.
    @State private var confirmForgetEntry: String?
    /// Node awaiting "forget entirely?" confirmation.
    @State private var confirmForgetNode: String?

    @State private var order: Order = .alias
    /// Hides rows nothing has offered a way to reach.
    ///
    /// They are not junk — resolving `DRLNOD` to `KE0NCQ` for a map pin or a
    /// via-path label needs no teller — but presenting them beside routable
    /// rows made the page read as 193 places to go when it was 95.
    @State private var reachableOnly: Bool = false

    enum Order: String, CaseIterable, Identifiable {
        case alias = "Alias"
        case recent = "Recently heard"
        case station = "Station"
        var id: String { rawValue }
    }

    /// One route and everything reachable through it.
    ///
    /// The page's structure, not a sort option. Ninety of ninety-nine rows
    /// shared the same route, so printing it on each one spent a column on
    /// the least surprising fact on screen while the thing that varies —
    /// which stations a given node can reach — had no shape at all.
    struct RouteGroup: Identifiable {
        let teller: String?
        let entries: [NodeAliasDirectory.Entry]
        var id: String { teller ?? "" }

        var title: String { teller.map { "Via \($0)" } ?? "No route known" }
    }

    /// Groups in the order the operator would work down them: the routes that
    /// reach most first, unreachable last because nothing can be done there.
    private var groups: [RouteGroup] {
        // Under a route filter every row is on the page *because* that node
        // listed it, so one section headed by it is the whole page. Re-filing
        // them under their freshest teller would answer a question nobody
        // asked, and would hide the one that was.
        if let node = routeFilter {
            return rows.isEmpty ? [] : [RouteGroup(teller: node, entries: rows)]
        }
        var byTeller: [String: [NodeAliasDirectory.Entry]] = [:]
        var orphans: [NodeAliasDirectory.Entry] = []
        for entry in rows {
            // Filed under the freshest node that listed it. An entry reachable
            // several ways appears once, under its best route — the sheet lists
            // the rest, and repeating the row per teller would inflate the
            // counts that make the sections worth reading.
            if let teller = entry.reachableVia.first {
                byTeller[teller, default: []].append(entry)
            } else {
                orphans.append(entry)
            }
        }
        var result = byTeller
            .map { RouteGroup(teller: $0.key, entries: $0.value) }
            .sorted {
                if $0.entries.count != $1.entries.count {
                    return $0.entries.count > $1.entries.count
                }
                return $0.id < $1.id
            }
        if !orphans.isEmpty {
            result.append(RouteGroup(teller: nil, entries: orphans))
        }
        return result
    }

    private var rows: [NodeAliasDirectory.Entry] {
        let all = aliases.directory.allEntries
        // Membership in the teller list, not just the freshest one: the
        // question the sidebar row asks is "if I connect to this node, what
        // can I ask it for", and being outbid on recency by another node
        // does not take anything off that node's table.
        let routed = routeFilter.map { aliases.directory.entries(reachableVia: $0) } ?? all
        let needle = query.trimmingCharacters(in: .whitespaces).uppercased()
        let matching = needle.isEmpty ? routed : routed.filter {
            $0.alias.contains(needle)
                || $0.callsign.contains(needle)
                || $0.reachableVia.contains { $0.contains(needle) }
        }
        let filtered = reachableOnly ? matching.filter { !$0.tellers.isEmpty } : matching
        switch order {
        case .alias: return filtered.sorted { $0.alias < $1.alias }
        case .station: return filtered.sorted { $0.callsign < $1.callsign }
        case .recent: return filtered.sorted { $0.heardAt > $1.heardAt }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if rows.isEmpty {
                empty
            } else {
                list
            }
        }
        .background(Color(platform: .platformWindowBackground))
        .confirmationDialog(
            "Forget \(confirmForgetEntry ?? "")?",
            isPresented: Binding(
                get: { confirmForgetEntry != nil },
                set: { if !$0 { confirmForgetEntry = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget It", role: .destructive) {
                if let alias = confirmForgetEntry { aliases.removeEntry(alias: alias) }
                confirmForgetEntry = nil
            }
            Button("Keep It", role: .cancel) { confirmForgetEntry = nil }
        } message: {
            Text("Removes the entry and every node's claim to it. The next "
                 + "announcement that lists it re-learns it from scratch.")
        }
        .confirmationDialog(
            "Forget \(confirmForgetNode ?? "") entirely?",
            isPresented: Binding(
                get: { confirmForgetNode != nil },
                set: { if !$0 { confirmForgetNode = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget the Node", role: .destructive) {
                if let node = confirmForgetNode {
                    aliases.removeNode(node)
                    if routeFilter == node { routeFilter = nil }
                }
                confirmForgetNode = nil
            }
            Button("Keep It", role: .cancel) { confirmForgetNode = nil }
        } message: {
            Text("Removes its directory entry and every claim it made about "
                 + "other stations — under both of its names. Its next "
                 + "announcement re-learns it from scratch.")
        }
        .confirmationDialog(
            "Forget \(forgettable.count) entries?",
            isPresented: $confirmingForget, titleVisibility: .visible
        ) {
            Button("Forget them", role: .destructive) {
                aliases.forget(knownCallsigns: knownCallsigns)
            }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text(forgetTooltip)
        }
    }

    private var forgettable: [NodeAliasDirectory.Entry] {
        aliases.directory.forgettable(knownCallsigns: knownCallsigns)
    }

    private var forgetTooltip: String {
        """
        These name stations no node has offered a route to, and that this \
        station has never seen in any packet. Nothing can be done with them and \
        nothing else is using them.

        Entries that resolve a name you do hear are kept even without a route. \
        And forgetting is cheap to undo: if a node lists one of these again it \
        comes back with a route attached, which is the form worth having.
        """
    }

    private var toolbar: some View {
        // No search field here. The window's own search field already drives
        // this page's `query` — the shell mirrors it into the same binding
        // this row used — so the page carried two fields that edited one
        // string, side by side, with two different placeholders describing
        // the same thing. The one in the toolbar is the one that also works
        // on every other page.
        HStack(spacing: 12) {
            // Says what the page is currently restricted to, and is the way
            // out of it. Arriving at a filtered page with no visible reason
            // for the missing rows is how the sidebar's jump used to read.
            if let node = routeFilter {
                Button { routeFilter = nil } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                        Text(node)
                            .font(.system(.caption, design: .monospaced))
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Showing only what \(node) listed. Others may list the same "
                      + "stations — click to drop the restriction and see every "
                      + "node's table.")

                Button { confirmForgetNode = node } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Forget \(node) entirely: its own entry and every claim "
                      + "it made about other stations. Re-learned from scratch "
                      + "the next time it announces.")
            }

            Picker("Sort", selection: $order) {
                ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            // Nothing for it to hide while a route filter is on: every row is
            // there because a node offered a way in.
            if routeFilter == nil {
                Toggle("Only ones I can reach", isOn: $reachableOnly)
                    .help("Hides entries no node has offered a route to. They still "
                          + "resolve names on the map and in via paths — there is just "
                          + "nowhere to connect to get to them.")
            }

            Spacer()

            if !forgettable.isEmpty {
                Button("Forget \(forgettable.count) dead") { confirmingForget = true }
                    .help(forgetTooltip)
            }

            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                // The count is the whole point of the page: it is the answer
                // to "is this being saved" that no other screen gives.
                .help("Aliases learned from node tables, ID frames and beacons. "
                      + "Names, not routes — see Routes for paths this station can reach.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Says how many of the names on file are actually actionable.
    ///
    /// The plain total was the misleading number: it counted every name the
    /// network has published, including the ones with no way in.
    private var countLabel: String {
        let all = aliases.directory.allEntries
        let reachable = all.count { !$0.tellers.isEmpty }
        if rows.count != all.count {
            return "\(rows.count) of \(all.count)"
        }
        if reachable == all.count {
            return all.count == 1 ? "1 alias" : "\(all.count) aliases"
        }
        return "\(all.count) aliases · \(reachable) reachable"
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "Nothing matches “\(query)”" }
        if let node = routeFilter { return "\(node) has not listed anything" }
        return "No aliases learned yet"
    }

    private var emptyDetail: String {
        if !query.isEmpty {
            return routeFilter == nil
                ? "Try a shorter search."
                : "Nothing under this node matches. Try a shorter search, or drop "
                  + "the route filter to search every node's table."
        }
        if routeFilter != nil {
            return "Its table has not been read since these entries were last "
                + "cleared. Connect and send N or NODES to collect one."
        }
        return "Aliases arrive in node tables, ID frames and beacons. "
            + "Connect to a node and send N or NODES to collect a batch."
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "questionmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.headline)
            Text(emptyDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries, id: \.alias) { entry in
                            if let onSelect {
                                // Opened by *alias*, not by the callsign behind
                                // it. The profile records which name led there
                                // and says so, and the alias is the name the
                                // operator just read.
                                Button {
                                    onSelect(entry.alias)
                                } label: {
                                    row(entry, under: group.teller)
                                }
                                    .buttonStyle(.plain)
                                    .help("Open \(entry.callsign)")
                                    .contextMenu { rowActions(entry, under: group.teller) }
                                    .popover(
                                        isPresented: Binding(
                                            get: { evidenceAlias == entry.alias },
                                            set: { if !$0 { evidenceAlias = nil } }),
                                        arrowEdge: .leading
                                    ) { evidenceView(entry) }
                            } else {
                                row(entry, under: group.teller)
                            }
                            Divider().padding(.leading, 12)
                        }
                    } header: {
                        // Only when the page is showing several. Under a route
                        // filter every row is under the same node and the
                        // toolbar chip already names it, so the header was one
                        // more statement of the least surprising fact on the
                        // page — and it read as a claim that the rows below it
                        // were a *different* section from the rows above.
                        if routeFilter == nil {
                            sectionHeader(group)
                        }
                    }
                }
            }
        }
        // A fresh scroll container per filter, and the top of it.
        //
        // Filtering to KB5YZB-7 left a "Via COSCO · 516" header sitting
        // twenty rows down a list that was, from top to bottom, one unbroken
        // run of KB5YZB-7's table — a heading for a section no longer on the
        // page. The lazy stack had materialised COSCO's section while the
        // page was unfiltered and kept the header cell alive when the set of
        // sections shrank to one; nothing in the group list said so, which is
        // why the count on it (516) belonged to no section on screen
        // (2026-08-27).
        .id(routeFilter ?? "")
    }

    /// Pinned so the route stays on screen while its stations scroll past —
    /// with ninety under one node, the answer to "through what?" would
    /// otherwise be off the top for most of the list.
    private func sectionHeader(_ group: RouteGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: group.teller == nil
                  ? "questionmark.circle" : "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(group.teller == nil ? AnyShapeStyle(.tertiary)
                                                     : AnyShapeStyle(.secondary))
            Text(group.title)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(group.teller == nil ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(.primary))
            Text("\(group.entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .help(group.teller.map {
            "Connect to \($0) and ask for any of these by name. It listed them, "
            + "so it knows how to get there."
        } ?? "Nothing has offered a way to reach these. They still resolve names "
            + "on the map and in via paths.")
    }

    /// ALIAS:CALL as one selectable run of text, alias carrying the weight.
    private func identityText(_ entry: NodeAliasDirectory.Entry) -> Text {
        let alias: Text = Text(entry.alias).fontWeight(.medium)
        let colon: Text = Text(":").foregroundColor(.secondary)
        let call: Text = Text(entry.callsign).foregroundColor(.secondary)
        return alias + colon + call
    }

    private func row(_ entry: NodeAliasDirectory.Entry, under teller: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // Written the way every node prints it: ALIAS:CALL. The old
            // alias → callsign arrow read as "connects to", as if the
            // alias were a hop toward the callsign — it is one station
            // with two names, and the colon is the convention operators
            // already know from BPQ prompts and NODES tables.
            identityText(entry)
                .font(.system(.body, design: .monospaced))
                .frame(width: 208, alignment: .leading)
                .textSelection(.enabled)
                .help("One station, two names — not a route. \(entry.alias) is "
                      + "the name the network answers to (what you type at a "
                      + "node prompt); \(entry.callsign) is the licensed "
                      + "station behind it.")

            // Only when the station itself declared one. Shown inline rather
            // than in a column of its own: fewer than one row in thirty has a
            // service, and a column that is empty thirty times over reads as
            // broken data instead of as absent evidence.
            if !entry.service.isEmpty {
                Text(serviceLabel(entry.service))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .help("What the station itself announced it runs. Most entries "
                          + "have none: a node's table says what can be reached, "
                          + "not what each station is.")
            }

            // Where the callsign is licensed, when that is somewhere else.
            // The prefix is a fact; what it implies about the path is left
            // to the operator — on VHF a row from another continent is
            // almost certainly reached over an internet link somewhere in
            // the chain, on long-haul HF it may be genuine RF, and this
            // station cannot observe which.
            if let region = foreignRegion(entry.callsign) {
                Text(region)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().strokeBorder(Color.secondary.opacity(0.35)))
                    .help("Licensed in \(region), read from the callsign prefix. "
                          + "The node claims a path; whether the hops beyond it are "
                          + "RF or internet links is not something this station can "
                          + "observe. On a VHF channel a path to another country "
                          + "almost certainly includes an internet link — on "
                          + "long-haul HF it may well be radio the whole way.")
            }

            // The other routes. The one heading this section is not repeated —
            // it was the same on ninety consecutive rows.
            if let label = otherRoutesLabel(entry, under: teller) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(reachTooltip(entry))
            }

            Spacer(minLength: 8)

            Text(entry.heardAt.formatted(.relative(presentation: .numeric)))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help(lastHeardTooltip(entry))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    /// The entry's licensing country when it differs from the operator's
    /// own — nil for domestic rows and unknown prefixes alike.
    private func foreignRegion(_ callsign: String) -> String? {
        guard let region = CallsignRegion.region(for: callsign) else { return nil }
        // Compared by country, not by refined region — two Australians in
        // different states are compatriots, not foreigners to each other.
        let home = CallsignRegion.country(for: localCallsign)
        return CallsignRegion.country(for: callsign) == home ? nil : region
    }

    /// The nodes that listed this station apart from the one heading its
    /// section — which is on screen already, at the top of the section.
    private func otherRoutes(
        _ entry: NodeAliasDirectory.Entry, under teller: String?
    ) -> [String] {
        guard let heading = teller?.uppercased() else { return entry.reachableVia }
        return entry.reachableVia.filter { $0.uppercased() != heading }
    }

    /// Names the other node when there is one, counts them when there are
    /// several.
    ///
    /// It read "+1 more" — more of what was left to a tooltip, on a badge
    /// carried by nearly every row on the page, because two nodes here publish
    /// substantially the same table. Naming the node answers the question on
    /// the row (2026-08-27).
    private func otherRoutesLabel(
        _ entry: NodeAliasDirectory.Entry, under teller: String?
    ) -> String? {
        let others = otherRoutes(entry, under: teller)
        switch others.count {
        case 0: return nil
        case 1: return "also via \(others[0])"
        default: return "+\(others.count) nodes"
        }
    }

    /// What can be done with a row, now that the sidebar no longer lists
    /// individual stations.
    @ViewBuilder
    private func rowActions(
        _ entry: NodeAliasDirectory.Entry, under teller: String?
    ) -> some View {
        // The section's node first, then the rest freshest-first. Under a
        // route filter the operator is reading one node's table, and offering
        // to connect through a different one as the default action answers a
        // question they did not ask.
        let routes = teller.map { heading in
            [heading] + otherRoutes(entry, under: heading)
        } ?? entry.reachableVia
        if let onConnect, let via = routes.first {
            Button("Connect via \(via)") { onConnect(entry.alias, via) }
            ForEach(routes.dropFirst(), id: \.self) { other in
                Button("Connect via \(other)") { onConnect(entry.alias, other) }
            }
            Divider()
        }
        if let onSelect {
            Button("Open Profile") { onSelect(entry.alias) }
        }
        Button("Why Is This Here?") { evidenceAlias = entry.alias }
        Button("Copy Alias") { ClipboardWriter.copy(entry.alias) }
        Button("Copy Callsign") { ClipboardWriter.copy(entry.callsign) }
        Divider()
        // Pruning, narrowest first: one node's claim, then the whole
        // entry. Anything removed is re-learned from the next
        // announcement — this clears data, not the willingness to listen.
        if let teller {
            Button("Remove \(teller)'s Claim", role: .destructive) {
                aliases.removeClaim(teller: teller, fromAlias: entry.alias)
            }
        }
        Button("Forget \(entry.alias)\u{2026}", role: .destructive) {
            confirmForgetEntry = entry.alias
        }
    }

    /// The receipts behind a row: who said it, when, how often.
    private func evidenceView(_ entry: NodeAliasDirectory.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(entry.alias):\(entry.callsign)")
                .font(.system(.headline, design: .monospaced))
            Text("Announced \(entry.announcements) time\(entry.announcements == 1 ? "" : "s") \u{2014} "
                 + "last \(entry.heardAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if entry.tellers.isEmpty {
                Text("No node has claimed a route here. The entry only resolves "
                     + "the name, for the map and via paths.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Divider()
                Text("Vouched for by")
                    .font(.caption.weight(.semibold))
                ForEach(entry.tellers.sorted(by: { $0.value > $1.value }), id: \.key) { teller, when in
                    HStack {
                        Text(teller)
                            .font(.system(.caption, design: .monospaced))
                        Spacer(minLength: 16)
                        Text(when.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text("Everything here was heard over the air \u{2014} a node's table "
                 + "is its claim, not a route this station has measured.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 260, alignment: .leading)
        }
        .padding(12)
    }

    /// Last-heard and corroboration in one tooltip.
    ///
    /// They were two columns, both near-constant down the page — every row of
    /// a single table pull shares a timestamp, and most claims are heard once.
    /// Neither earned standing width.
    private func lastHeardTooltip(_ entry: NodeAliasDirectory.Entry) -> String {
        let stamp = entry.heardAt.formatted(date: .abbreviated, time: .shortened)
        let corroboration = entry.announcements == 1
            ? "Announced once."
            : "Announced \(entry.announcements) separate times — repetition is the "
              + "only corroboration available for a claim no directory can check."
        return "Last announced \(stamp). \(corroboration)"
    }

    private func reachTooltip(_ entry: NodeAliasDirectory.Entry) -> String {
        let lines = entry.reachableVia.map { teller -> String in
            let when = entry.tellers[teller]?.formatted(
                .relative(presentation: .numeric)) ?? "unknown"
            return "\(teller) — listed it \(when)"
        }
        let heading = lines.count == 1
            ? "Connect to this node and ask for \(entry.alias):"
            : "Any of these listed \(entry.alias); newest first:"
        return ([heading] + lines).joined(separator: "\n")
    }

    /// Service codes travel as single letters and the conventions vary between
    /// stacks, so unknown ones are shown verbatim rather than guessed at.
    private func serviceLabel(_ code: String) -> String {
        switch code.uppercased() {
        case "N": return "node"
        case "B": return "BBS"
        case "D": return "digipeater"
        case "G": return "gateway"
        case "R": return "relay"
        case "": return ""
        default: return code.lowercased()
        }
    }
}
