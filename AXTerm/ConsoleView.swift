//
//  ConsoleView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 1/28/26.
//

import SwiftUI

nonisolated struct ConsoleTypeFilterFlags: Equatable, Sendable {
    var showID: Bool = true
    var showBeacon: Bool = true
    var showMail: Bool = true
    var showData: Bool = true
    var showPrompt: Bool = true
    var showOther: Bool = true
    var showSystem: Bool = true
    /// Show digipeated copies of the local station's own frames (off by default —
    /// they carry no new content, but confirm the digi is actually relaying us).
    var showDigipeats: Bool = false
    /// Show *nothing but* those echoes. Not a message class — an echo is
    /// still an ID or a DATA line — so this is a separate axis rather than
    /// another flag in the set above.
    var digipeatsOnly: Bool = false
    /// Show only lines this station is a party to — sent by us, addressed to
    /// us, or digipeated by us.
    ///
    /// The single biggest lever on a busy channel: on this operator's own
    /// capture, 71% of frames involve neither end of their station, and a
    /// stranger's Winlink session can fill the console for minutes at a time.
    /// Another axis rather than a class, for the same reason as
    /// `digipeatsOnly` — our own traffic is still IDs and DATA.
    var minesOnly: Bool = false

    /// One switch on the filter row.
    enum Kind: String, CaseIterable, Hashable, Sendable {
        case id, beacon, mail, data, prompt, other, system, mine, digipeats

        /// The chip's label, and the word used in "Show Only …".
        var label: String {
            switch self {
            case .id: return "ID"
            case .beacon: return "BCN"
            case .mail: return "MAIL"
            case .data: return "DATA"
            case .prompt: return "CMD"
            case .other: return "OTHER"
            case .system: return "SYS"
            case .mine: return "MINE"
            case .digipeats: return "DIGI"
            }
        }

        /// The seven that partition the console. MINE and DIGI are excluded:
        /// they narrow the same lines rather than naming a kind of line, so
        /// treating them as classes would let "show only mine" mean "show
        /// nothing".
        static var messageClasses: [Kind] {
            allCases.filter { !$0.isAxis }
        }

        /// True for the switches that filter across every class instead of
        /// selecting one.
        var isAxis: Bool { self == .mine || self == .digipeats }
    }

    subscript(kind: Kind) -> Bool {
        get {
            switch kind {
            case .id: return showID
            case .beacon: return showBeacon
            case .mail: return showMail
            case .data: return showData
            case .prompt: return showPrompt
            case .other: return showOther
            case .system: return showSystem
            case .mine: return minesOnly
            case .digipeats: return showDigipeats
            }
        }
        set {
            switch kind {
            case .id: showID = newValue
            case .beacon: showBeacon = newValue
            case .mail: showMail = newValue
            case .data: showData = newValue
            case .prompt: showPrompt = newValue
            case .other: showOther = newValue
            case .system: showSystem = newValue
            case .mine: minesOnly = newValue
            case .digipeats: showDigipeats = newValue
            }
        }
    }

    /// Show this one and nothing else — the mixing-desk solo, so isolating a
    /// class costs one gesture instead of switching off the other seven.
    ///
    /// Soloing a message class leaves `showDigipeats` alone: an echoed DATA
    /// frame is still DATA, and whether the operator wants to see their own
    /// echoes is a separate preference from which classes they are reading.
    mutating func solo(_ kind: Kind) {
        switch kind {
        case .digipeats:
            // "Only DIGI" cannot mean "no message classes" — that shows an
            // empty console, because every echo is also an ID or a DATA line.
            for klass in Kind.messageClasses { self[klass] = true }
            showDigipeats = true
            digipeatsOnly = true
            minesOnly = false
        case .mine:
            // Same shape: our own traffic is still IDs and DATA.
            for klass in Kind.messageClasses { self[klass] = true }
            minesOnly = true
            digipeatsOnly = false
        default:
            for klass in Kind.messageClasses { self[klass] = (klass == kind) }
            digipeatsOnly = false
            minesOnly = false
        }
    }

    func isSoloed(_ kind: Kind) -> Bool {
        switch kind {
        case .digipeats: return digipeatsOnly && showDigipeats && !minesOnly
        case .mine: return minesOnly && !digipeatsOnly && isShowingEveryClass
        default:
            guard !digipeatsOnly, !minesOnly else { return false }
            return Kind.messageClasses.allSatisfy { self[$0] == ($0 == kind) }
        }
    }

    /// Back to every class. Deliberately does not touch `showDigipeats`:
    /// echoes are off by default because they are noise, and restoring the
    /// classes should not quietly turn the operator's own echoes back on.
    mutating func showAllTypes() {
        for klass in Kind.messageClasses { self[klass] = true }
        digipeatsOnly = false
        minesOnly = false
    }

    /// Every message class switched on. Says nothing about the axes — a
    /// console showing only our own traffic is still showing every class of
    /// it.
    var isShowingEveryClass: Bool {
        Kind.messageClasses.allSatisfy { self[$0] }
    }

    /// Nothing filtered at all, on either axis.
    var isUnrestricted: Bool {
        isShowingEveryClass && !digipeatsOnly && !minesOnly
    }

    /// What is being held back, for the line beside the message count. Nil
    /// when every class is showing.
    var restrictionSummary: String? {
        var parts: [String] = []
        if minesOnly { parts.append("my traffic only") }
        if digipeatsOnly { parts.append("digipeat echoes only") }
        if let classes = classRestriction { parts.append(classes) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{b7} ")
    }

    private var classRestriction: String? {
        let shown = Kind.messageClasses.filter { self[$0] }
        if shown.count == Kind.messageClasses.count { return nil }
        if shown.isEmpty { return "every type hidden" }
        if shown.count == 1 { return "\(shown[0].label) only" }
        let hidden = Kind.messageClasses.filter { !self[$0] }
        return "no \(hidden.map(\.label).joined(separator: "/"))"
    }
}

nonisolated enum ConsoleVisibilityFilter {
    static func apply(
        lines: [ConsoleLine],
        clearedAt: Date?,
        flags: ConsoleTypeFilterFlags,
        localCallsign: String = ""
    ) -> [ConsoleLine] {
        let timeFiltered: [ConsoleLine]
        if let cutoff = clearedAt {
            timeFiltered = lines.filter { $0.timestamp > cutoff }
        } else {
            timeFiltered = lines
        }

        return timeFiltered.filter { line in
            // Digipeated echoes of our own frames are copies, not content — hidden
            // unless the operator opts in. Frames FROM other stations heard via a
            // digi are the session content itself and are never hidden here.
            let isEcho = line.isDigipeatEcho(localCallsign: localCallsign)
            if !flags.showDigipeats, isEcho {
                return false
            }
            // "Only DIGI": every line that is not one of our own echoes goes.
            if flags.digipeatsOnly, !isEcho {
                return false
            }
            // "Only MINE": lines this station is not a party to go. Needs a
            // callsign to mean anything — with none set, every line would
            // vanish, which is a worse answer than not filtering.
            if flags.minesOnly, !localCallsign.isEmpty,
               !line.involvesStation(localCallsign) {
                return false
            }
            switch line.kind {
            case .system, .error:
                return flags.showSystem
            case .packet:
                guard let messageType = line.messageType else { return flags.showOther }
                switch messageType {
                case .id: return flags.showID
                case .beacon: return flags.showBeacon
                case .mail: return flags.showMail
                case .data: return flags.showData
                case .prompt: return flags.showPrompt
                case .message: return flags.showOther
                }
            }
        }
    }
}

struct ConsoleView: View {
    /// Console text size, from the operator's setting. Eleven points is
    /// the historical default, not everyone's eyes.
    var fontSize: Double = 11
    let lines: [ConsoleLine]
    let showDaySeparators: Bool
    @Binding var clearedAt: Date?
    /// Local station callsign, used to recognize digipeated copies of our own
    /// frames. Empty disables digipeat-echo handling (nothing is hidden).
    var localCallsign: String = ""
    /// Tapping a callsign in a line asks who it is. Nil keeps the console
    /// read-only, which is what the Mac wants.
    var onIdentity: ((String) -> Void)?
    var onIdentityMenu: ((String) -> Void)?
    /// Bump from the parent to force a bottom re-pin even when the line set is
    /// unchanged. The Broadcast⇄Session toggle re-lays-out this ScrollView
    /// without changing its content, which can strand the newest lines above the
    /// viewport; on a quiet channel no incoming packet rebuilds the list to fix
    /// it, so the parent signals the toggle here directly. See `scheduleRepin`.
    var repinSignal: Int = 0

    @State private var autoScroll = true
    @State private var isUserNearBottom = true
    @State private var scrollViewHeight: CGFloat = 0
    @State private var showUndoClear = false
    @State private var undoClearTask: Task<Void, Never>?
    @State private var previousClearedAt: Date?
    @State private var scrollToBottomToken = 0
    /// Pending debounced write of `isUserNearBottom` from the bottom sentinel.
    @State private var nearBottomWork: DispatchWorkItem?
    /// Pending debounced re-pin after the visible line set changes (see `scheduleRepin`).
    @State private var repinWork: DispatchWorkItem?

    // Message type filters — persisted across view switches and app restarts
    @AppStorage("consoleFilter_showID") private var showID = true
    @AppStorage("consoleFilter_showBeacon") private var showBeacon = true
    @AppStorage("consoleFilter_showMail") private var showMail = true
    @AppStorage("consoleFilter_showData") private var showData = true
    @AppStorage("consoleFilter_showPrompt") private var showPrompt = true
    @AppStorage("consoleFilter_showOther") private var showOther = true
    @AppStorage("consoleFilter_showSystem") private var showSystem = true
    @AppStorage("consoleFilter_showDigipeats") private var showDigipeats = false
    @AppStorage("consoleFilter_digipeatsOnly") private var digipeatsOnly = false
    @AppStorage("consoleFilter_minesOnly") private var minesOnly = false

    /// Which rows print their time. Computed with the grouping rather than
    /// per row: asking each row about the one above it would be a lookup per
    /// row per render on a list that grows all day.
    private var timestampRunPositions: [ConsoleLineGroup.ID: ConsoleTimestampRuler.RunPosition] {
        ConsoleTimestampRuler.runPositions(groupedLines, timestamp: \.primary.timestampString)
    }

    /// Lines filtered by clear timestamp and message type preferences
    private var typeFilteredLines: [ConsoleLine] {
        ConsoleVisibilityFilter.apply(
            lines: lines,
            clearedAt: clearedAt,
            flags: currentFilterFlags,
            localCallsign: localCallsign
        )
    }

    /// The rendered console, rebuilt only when something it depends on changes.
    ///
    /// These used to be computed properties read from `body`, which meant the
    /// whole pipeline — filter every line, group duplicates, split by day — ran
    /// on **every** body evaluation, over a buffer that sits pegged at its
    /// 10,000-line cap on a busy channel. Packets arrive continuously, so the
    /// main thread spent its time re-deriving a list that had barely changed,
    /// and the app stopped responding. CLAUDE.md §12: no unbounded view-driven
    /// loops.
    ///
    /// `LazyVStack` does not save this: the array has to be fully materialised
    /// before it can be lazy about drawing it.
    @State private var groupedLines: [ConsoleLineGroup] = []
    @State private var dayGroupedLines: [DayGroupedSection<ConsoleLineGroup>] = []

    /// Everything the rendered console depends on, as one comparable value.
    ///
    /// `lines.count` alone is not enough: once the buffer is full every append
    /// also trims, so the count stays at 10,000 while the content changes
    /// underneath. The newest line's identity is what actually moves.
    private var renderInputs: String {
        let flags = [showID, showBeacon, showMail, showData,
                     showPrompt, showOther, showSystem, showDigipeats]
            .map { $0 ? "1" : "0" }.joined()
        return "\(lines.count)|\(lines.last?.id.uuidString ?? "-")|"
            + "\(clearedAt?.timeIntervalSince1970 ?? 0)|\(flags)|\(localCallsign)"
    }

    private func rebuildRenderedLines() {
        let groups = ConsoleLineGrouper.group(typeFilteredLines)
        groupedLines = groups
        dayGroupedLines = DayGrouping.group(items: groups, date: { $0.primary.timestamp })
        // Any change to the visible line set can leave the ScrollView holding an
        // offset that no longer matches the content — most visibly when the
        // Session⇄Broadcast toggle swaps in a different filtered set (its peer
        // filter turns on with an active session), stranding the newest lines
        // above the viewport with blank space below. Re-pin AFTER the rebuild
        // settles. See `scheduleRepin`.
        scheduleRepin()
    }

    /// Coalesce the bottom sentinel's near-bottom signal. Cancels any pending
    /// write and schedules a fresh one a short quiet-window later, so a burst of
    /// appear/disappear flips (rapid appends + scroll-to-bottom) collapses to a
    /// single write once the scrolling settles — never a per-flip write storm
    /// inside the update pass. The write runs on a later main-queue turn, so it
    /// also can't recurse synchronously through `propagate_dirty`.
    private func scheduleNearBottom(_ value: Bool) {
        nearBottomWork?.cancel()
        let work = DispatchWorkItem {
            if isUserNearBottom != value { isUserNearBottom = value }
        }
        nearBottomWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Re-pin the transcript to the bottom AFTER the visible line set settles.
    ///
    /// The Session⇄Broadcast toggle does NOT change the compose bar's height —
    /// both layouts are two rows — so the console is not resized. What changes is
    /// its CONTENT: `connectionMode` drives the session-peer filter, so toggling
    /// can swap in a different (often much shorter) filtered set. `.onChange(of:
    /// groupedLines.count)` misses this when the count happens to match, and even
    /// when it fires, a `scrollTo` in the same pass resolves the bottom against a
    /// half-applied layout and can overshoot — an intermittent, timing-dependent
    /// strand of the newest lines above the viewport.
    ///
    /// Deferring past the settle removes the race: the scroll runs after the new
    /// content is laid out. Cancel-and-reschedule collapses a burst of rebuilds
    /// (live packets) to a single re-pin once they stop. It targets the last real
    /// line, never the phantom "bottom" sentinel an overshoot would land past.
    /// Only while Auto-scroll is on, so a reader who scrolled up is left alone.
    private func scheduleRepin() {
        guard autoScroll else { return }
        repinWork?.cancel()
        let work = DispatchWorkItem { scrollToBottomToken += 1 }
        repinWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Toolbar
                HStack(spacing: 12) {
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .platformCheckboxToggle()

                    Spacer()

                    // Filter toggles
                    filterToggleGroup

                    Divider()
                        .frame(height: 16)

                    // Naming the restriction, not just implying it with dim
                    // chips: an operator who soloed DATA an hour ago and came
                    // back to a quiet console should not have to audit eight
                    // switches to find out why.
                    HStack(spacing: 4) {
                        Text("\(groupedLines.count) messages")
                        if let restriction = currentFilterFlags.restrictionSummary {
                            Text("\u{b7} \(restriction)")
                                .foregroundStyle(.orange)
                            Button("Show All") { applyFlags { $0.showAllTypes() } }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help("Turn every message type back on.")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .font(.caption)

                    Button(action: {
                        clearConsole()
                    }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help("Clear Console")
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: ConsoleTheme.rowSpacing) {
                            if showDaySeparators {
                                ForEach(dayGroupedLines) { section in
                                    DaySeparatorView(date: section.date)
                                        .padding(.vertical, 4)

                                    // Computed per section: a day separator
                                    // starts a new block, so the row after
                                    // one always prints its time.
                                    let runs = ConsoleTimestampRuler.runPositions(
                                        section.items, timestamp: \.primary.timestampString)
                                    ForEach(section.items) { group in
                                        ConsoleLineGroupView(fontSize: fontSize, group: group, localCallsign: localCallsign,
                                                             timestampRun: runs[group.id] ?? .alone,
                                                             onIdentity: onIdentity,
                                                             onIdentityMenu: onIdentityMenu)
                                            .id(group.id)
                                    }
                                }
                            } else {
                                ForEach(groupedLines) { group in
                                    ConsoleLineGroupView(fontSize: fontSize, group: group, localCallsign: localCallsign,
                                                             timestampRun: timestampRunPositions[group.id] ?? .alone,
                                                             onIdentity: onIdentity,
                                                             onIdentityMenu: onIdentityMenu)
                                        .id(group.id)
                                }
                            }
                            Color.clear
                                .frame(height: 10)
                                .id("bottom")
                                // DEBOUNCED, never a synchronous write. These
                                // appearance actions fire from inside SwiftUI's
                                // update pass; a burst of console appends with the
                                // scroll-to-bottom below makes this sentinel flip
                                // appeared/disappeared many times per pass, and
                                // writing `isUserNearBottom` on each flip re-dirties
                                // the attribute graph inside the same pass —
                                // `propagate_dirty` recursing into a 100% main-thread
                                // stack (sampled twice, 2026-08-29/30, leaf here).
                                //
                                // The write is coalesced through `scheduleNearBottom`,
                                // which cancels-and-reschedules: during a flip storm
                                // every scheduled write is cancelled by the next flip,
                                // so ZERO writes land until the scrolling settles, when
                                // one final write applies the real value. (A naive
                                // deferred write — schedule on every flip without
                                // cancelling — is the opposite trap: it re-fires every
                                // turn into a 100% async loop. Cancel-and-reschedule is
                                // the difference.)
                                .onAppear { scheduleNearBottom(true) }
                                .onDisappear { scheduleNearBottom(false) }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: groupedLines.count) { _, _ in
                        guard autoScroll else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: scrollToBottomToken) { _, _ in
                        // Pin to the last real line, not the phantom "bottom"
                        // sentinel below the padding — anchoring to the sentinel is
                        // what an overshoot lands past. No animation: this fires
                        // after a settle (`scheduleRepin`) or on appear, where a
                        // slide would just look like the overshoot we're correcting.
                        if let lastId = groupedLines.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        } else {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: autoScroll) { _, newValue in
                        if newValue {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        scrollToBottomToken += 1
                    }
                    .onChange(of: repinSignal) { _, _ in
                        scheduleRepin()
                    }
                }
                .background(.background)
                // Rebuilt here rather than read from `body`: see
                // `groupedLines`. One pass per actual change instead of one
                // per view evaluation.
                .onAppear { rebuildRenderedLines() }
                .onChange(of: renderInputs) { _, _ in rebuildRenderedLines() }
            }

            // Undo clear banner
            if showUndoClear {
                undoClearBanner
                    .padding(12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Jump to Bottom Button.
            //
            // Always in the tree, shown/hidden by opacity + scale — never by
            // `if`, and animated by a modifier scoped to the button alone.
            //
            // Why: this button's visibility is driven by `isUserNearBottom`,
            // which the bottom sentinel flips from its onAppear/onDisappear. If
            // toggling the button reflowed the ScrollView — or if an animation
            // on the whole ZStack animated the ScrollView on each flip — the
            // reflow moved the sentinel across its own visibility boundary,
            // flipped the flag again, and re-armed the animation: a self-
            // sustaining 100% main-thread layout loop that beach-balled the app
            // (sampled 2026-08-29; kicked off by any layout nudge, e.g. opening
            // the routing popover). Kept as a pure overlay and animating only
            // opacity/scale (render transforms, not layout), the flag can no
            // longer feed back into layout, so it cannot oscillate.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        isUserNearBottom = true // Optimistic update
                        autoScroll = true
                        scrollToBottomToken += 1
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .foregroundStyle(.secondary, .regularMaterial)
                            .background(Circle().fill(.background))
                            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding([.bottom, .trailing], 20)
                }
            }
            .opacity(isUserNearBottom ? 0 : 1)
            .scaleEffect(isUserNearBottom ? 0.8 : 1, anchor: .bottomTrailing)
            .allowsHitTesting(!isUserNearBottom)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isUserNearBottom)
        }
        .animation(.easeInOut(duration: 0.2), value: showUndoClear)
    }

    // MARK: - Filter Toggles

    @ViewBuilder
    private var filterToggleGroup: some View {
        HStack(spacing: 4) {
            ForEach(ConsoleTypeFilterFlags.Kind.messageClasses, id: \.self) { kind in
                chip(kind)
            }
            // MINE and DIGI narrow every class rather than selecting one, and
            // sitting them flush against the class chips read as "nine kinds
            // of line". Both need a callsign to mean anything: without one
            // there is no way to tell our traffic, or our echo, from anyone
            // else's.
            if !localCallsign.isEmpty {
                Divider().frame(height: 12).padding(.horizontal, 2)
                chip(.mine)
                chip(.digipeats)
            }
        }
    }

    private func chip(_ kind: ConsoleTypeFilterFlags.Kind) -> some View {
        FilterToggle(
            label: kind.label,
            isOn: binding(for: kind),
            color: color(for: kind),
            tooltip: tooltip(for: kind),
            isSoloed: currentFilterFlags.isSoloed(kind),
            onSolo: { applyFlags { $0.solo(kind) } },
            onShowAll: { applyFlags { $0.showAllTypes() } })
    }

    /// The eight switches as one value, so solo can reason about the set
    /// rather than about eight independent booleans.
    private var currentFilterFlags: ConsoleTypeFilterFlags {
        ConsoleTypeFilterFlags(
            showID: showID, showBeacon: showBeacon, showMail: showMail,
            showData: showData, showPrompt: showPrompt, showOther: showOther,
            showSystem: showSystem, showDigipeats: showDigipeats,
            digipeatsOnly: digipeatsOnly, minesOnly: minesOnly)
    }

    private func applyFlags(_ change: (inout ConsoleTypeFilterFlags) -> Void) {
        var flags = currentFilterFlags
        change(&flags)
        showID = flags.showID
        showBeacon = flags.showBeacon
        showMail = flags.showMail
        showData = flags.showData
        showPrompt = flags.showPrompt
        showOther = flags.showOther
        showSystem = flags.showSystem
        showDigipeats = flags.showDigipeats
        digipeatsOnly = flags.digipeatsOnly
        minesOnly = flags.minesOnly
    }

    private func binding(for kind: ConsoleTypeFilterFlags.Kind) -> Binding<Bool> {
        switch kind {
        case .mine: return $minesOnly
        case .id: return $showID
        case .beacon: return $showBeacon
        case .mail: return $showMail
        case .data: return $showData
        case .prompt: return $showPrompt
        case .other: return $showOther
        case .system: return $showSystem
        case .digipeats: return $showDigipeats
        }
    }

    private func color(for kind: ConsoleTypeFilterFlags.Kind) -> Color {
        switch kind {
        case .mine: return .pink
        case .id: return .blue
        case .beacon: return .green
        case .mail: return .orange
        case .data: return .purple
        case .prompt: return .cyan
        case .other: return .brown
        case .system: return .gray
        case .digipeats: return .indigo
        }
    }

    private func tooltip(for kind: ConsoleTypeFilterFlags.Kind) -> String {
        switch kind {
        case .mine:
            return "Only traffic this station is a party to \u{2014} sent by you, addressed to you, or digipeated by you. Matches any SSID of your callsign. On this channel most frames are conversations between other stations."
        case .id:
            return "Station identification broadcasts. Stations periodically announce their callsign and capabilities."
        case .beacon:
            return "Beacon messages. Periodic broadcasts containing station info, location, or status updates."
        case .mail:
            return "Mail notifications. Alerts about new messages waiting at a BBS or mailbox."
        case .data:
            return "Content messages. The actual data being exchanged \u{2014} personal messages, bulletins, and transferred information."
        case .prompt:
            return "AX.25 Link Control frames. Protocol-level session messages like SABM, DISC, RR, and UA."
        case .other:
            return "Unclassified messages. Packets that don't fit other categories."
        case .system:
            return "System messages. Connection status, errors, and internal application notifications."
        case .digipeats:
            return "Digipeater transmissions. Off-air copies of your own frames as repeated by a digipeater (marked \u{21bb}). They carry no new content, but seeing them confirms the digi is actually relaying you."
        }
    }

    // MARK: - Clear Actions

    private func clearConsole() {
        undoClearTask?.cancel()
        previousClearedAt = clearedAt
        clearedAt = Date()
        showUndoClear = true

        undoClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled {
                withAnimation {
                    showUndoClear = false
                    previousClearedAt = nil
                }
            }
        }
    }

    private func undoClear() {
        undoClearTask?.cancel()
        clearedAt = previousClearedAt
        previousClearedAt = nil
        withAnimation {
            showUndoClear = false
        }
    }

    @ViewBuilder
    private var undoClearBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)

            Text("Console cleared")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Undo") {
                undoClear()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}

// MARK: - Console Line Grouping

nonisolated enum ConsoleLineGrouper {
    static func group(_ lines: [ConsoleLine]) -> [ConsoleLineGroup] {
        var groups: [ConsoleLineGroup] = []
        var signatureToIndex: [String: Int] = [:]

        for line in lines {
            // Consecutive grouping for system/error messages
            if line.kind == .system || line.kind == .error {
                if let lastGroup = groups.last, lastGroup.primary.kind == line.kind, lastGroup.primary.text == line.text {
                    groups[groups.count - 1].duplicates.append(line)
                    continue
                }
            } else if line.isDuplicate,
               let signature = line.contentSignature,
               let existingIndex = signatureToIndex[signature] {
                groups[existingIndex].duplicates.append(line)
                continue
            }

            let group = ConsoleLineGroup(primary: line)
            if let signature = line.contentSignature {
                signatureToIndex[signature] = groups.count
            }
            groups.append(group)
        }

        return groups
    }
}

// MARK: - Console Line Group

/// Groups a primary console line with its duplicates (received via different paths)
nonisolated struct ConsoleLineGroup: Identifiable {
    let id: UUID
    let primary: ConsoleLine
    var duplicates: [ConsoleLine]

    init(primary: ConsoleLine) {
        self.id = primary.id
        self.primary = primary
        self.duplicates = []
    }

    /// All via paths (primary + duplicates)
    var allViaPaths: [[String]] {
        var paths: [[String]] = []
        if !primary.via.isEmpty {
            paths.append(primary.via)
        }
        for dup in duplicates {
            if !dup.via.isEmpty {
                paths.append(dup.via)
            }
        }
        return paths
    }

    var duplicateCount: Int {
        duplicates.count
    }
}

/// View for a grouped console line (primary + collapsed duplicates)
struct ConsoleLineGroupView: View {
    var fontSize: Double = 11
    let group: ConsoleLineGroup
    var localCallsign: String = ""
    /// Where this row sits among the rows sharing one displayed time.
    var timestampRun: ConsoleTimestampRuler.RunPosition = .alone
    var onIdentity: ((String) -> Void)?
    var onIdentityMenu: ((String) -> Void)?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleLineView(
                fontSize: fontSize,
                line: group.primary,
                timestampRun: timestampRun,
                duplicateCount: group.duplicateCount,
                allViaPaths: group.allViaPaths,
                localCallsign: localCallsign,
                onIdentity: onIdentity,
                onIdentityMenu: onIdentityMenu
            )

            // Expanded duplicates (if any and expanded)
            if isExpanded && group.duplicateCount > 0 {
                // Show primary's path first if it has one
                if !group.primary.via.isEmpty {
                    HStack(spacing: 4) {
                        Text("├")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: fontSize, design: .monospaced))
                        Text("via")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: fontSize, design: .monospaced))
                        Text(group.primary.viaDisplay)
                            .foregroundStyle(.purple)
                            .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                        Text("at \(group.primary.timestampString)")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: fontSize, design: .monospaced))
                    }
                    .padding(.leading, 20)
                    .padding(.vertical, 1)
                }

                // Show each duplicate's path
                ForEach(Array(group.duplicates.enumerated()), id: \.element.id) { index, dup in
                    let isLast = index == group.duplicates.count - 1 && group.primary.via.isEmpty
                    HStack(spacing: 4) {
                        Text(isLast ? "└" : "├")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: fontSize, design: .monospaced))

                        if !dup.via.isEmpty {
                            Text("via")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: fontSize, design: .monospaced))
                            Text(dup.viaDisplay)
                                .foregroundStyle(.purple)
                                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                        } else if group.primary.kind == .packet {
                            Text("(no digi path recorded)")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: fontSize, design: .monospaced))
                        }

                        Text("at \(dup.timestampString)")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: fontSize, design: .monospaced))
                    }
                    .padding(.leading, 20)
                    .padding(.vertical, 1)
                }
            }
        }
        // Only claim taps when there is something to expand.
        //
        // Attached unconditionally, this gesture covered the whole row and
        // swallowed every tap and right-click aimed at the callsigns inside
        // it — the identity view opened only on rows that happened to escape
        // it. The guard used to be inside the closure, which is too late:
        // the gesture had already consumed the event.
        .modifier(ExpandDuplicatesTap(isEnabled: group.duplicateCount > 0,
                                      isExpanded: $isExpanded))
    }
}

/// Row-level tap, installed only where it does something.
private struct ExpandDuplicatesTap: ViewModifier {
    let isEnabled: Bool
    @Binding var isExpanded: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                }
        } else {
            content
        }
    }
}

struct ConsoleLineView: View {
    var fontSize: Double = 11
    let line: ConsoleLine
    /// Where this row sits among the rows sharing one displayed time. Decides
    /// whether the time is printed and how the row is tied to the one above.
    var timestampRun: ConsoleTimestampRuler.RunPosition = .alone
    var duplicateCount: Int = 0
    var allViaPaths: [[String]] = []
    var localCallsign: String = ""
    /// Tapping a callsign asks who it is. Nil leaves the text inert, which is
    /// what the Mac's console wants — there a callsign is something you copy.
    var onIdentity: ((String) -> Void)?
    /// Long press: the menu of things you can do with an identity.
    var onIdentityMenu: ((String) -> Void)?

    private let callsignSaturation: Double = 0.35
    private let callsignBrightness: Double = 0.75

    /// A digipeated copy of our own frame — shown dimmed with a repeat marker
    /// so it reads as the digi's transmission, not new traffic.
    private var isDigipeatEcho: Bool {
        line.isDigipeatEcho(localCallsign: localCallsign)
    }

    private func repeatHelp(_ attribution: ConsoleLine.RepeatAttribution) -> String {
        let digis = attribution.digis.joined(separator: ", ")
        switch attribution {
        case .ourFrameEchoed:
            return "Our own frame, repeated back by \(digis)."
        case .heardVia:
            // The distinction that matters: this copy came off the digi's
            // transmitter, so it says nothing about whether the originating
            // station is audible here.
            return "Heard as \(digis)'s retransmission, not from "
                 + "\(line.from ?? "the sender") directly."
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Enhanced indicator bar with premium styling for system/error messages
            indicatorBar

            // Printed on every row, dimmed where it repeats the row above.
            //
            // Suppressing it outright left a blank, and a blank in the
            // leftmost column reads as a time that failed to appear rather
            // than one that was inherited. The fix for that was a hairline
            // tying the run together — but a full-height rule between two
            // columns is a column divider, and one that exists only on
            // grouped runs appears and disappears as the log scrolls. It read
            // as broken chrome for as long as it existed.
            //
            // So don't create the blank. A quiet repeat says "same second"
            // without inventing a mark to explain itself, every row can be
            // read on its own, and nothing in the gutter flickers.
            Text(line.timestampString)
                .foregroundStyle(.tertiary)
                .font(.system(size: fontSize, design: .monospaced))
                .opacity(timestampRun.printsTimestamp ? 1 : ConsoleTheme.repeatedTimestampOpacity)
                .help(line.timestampString)

            // Which transmitter we actually heard. Shown for *any* repeated
            // copy, not just echoes of our own frames: a station's beacon
            // heard direct and heard off a digi arrive a second apart with
            // identical text, and without this marker the two rows are the
            // same words — so "I hear KB5YZB-7" and "DRLNOD hears KB5YZB-7"
            // looked like a duplicate (2026-08-31).
            if let attribution = line.repeatAttribution(localCallsign: localCallsign) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text(attribution.digis.joined(separator: ","))
                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(.indigo)
                .help(repeatHelp(attribution))
                .accessibilityLabel(repeatHelp(attribution))
            }

            // Callsigns
            if let from = line.from {
                callsign(from)

                if let to = line.to {
                    Text("\u{2192}")
                        .foregroundStyle(.tertiary)

                    callsign(to)
                }
            }

            // Via path indicator (icon with tooltip)
            if !allViaPaths.isEmpty {
                DigiPathIndicator(paths: allViaPaths)
            } else if !line.via.isEmpty {
                DigiPathIndicator(paths: [line.via])
            }

            // Duplicate count badge
            if duplicateCount > 0 {
                DuplicateCountBadge(count: duplicateCount, kind: line.kind)
            }

            // Message text (wraps to container width; no chopping)
            Text(line.text)
                .foregroundStyle(messageColor)
                .textSelection(.enabled)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, ConsoleTheme.rowPadding)
        .padding(.horizontal, ConsoleTheme.rowPadding)
        // Shaped background, not a clip. `.cornerRadius` clips the row's
        // contents to the rounded rect, which silently truncates anything
        // that means to overhang the row; `.background(_:in:)` paints the
        // same shape without imposing a clip on the children.
        .background(premiumBackground,
                    in: RoundedRectangle(cornerRadius: ConsoleTheme.rowCornerRadius,
                                         style: .continuous))
        .opacity(isDigipeatEcho ? 0.6 : 1.0)
    }
    
    /// One callsign: plain text, or a tap target when someone is listening.
    ///
    /// Deliberately not a `Button` — a button style would fight the monospaced
    /// console layout and add padding that breaks the column alignment every
    /// line depends on. A tap gesture keeps the row exactly as it looked.
    @ViewBuilder
    private func callsign(_ call: String) -> some View {
        let text = Text(call)
            .fontWeight(.medium)
            .foregroundStyle(callsignColor(for: call))

        if let onIdentity {
            // `.onTapGesture` beside `.onLongPressGesture` is unreliable: the
            // long-press recogniser can consume the tap, so a callsign opened
            // its profile sometimes and did nothing other times. A
            // simultaneous gesture lets both live, and the Mac gets a
            // right-click menu instead of a press-and-hold it has no idiom for.
            text
                .contentShape(Rectangle())
                .onTapGesture { onIdentity(call) }
                #if os(iOS)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in (onIdentityMenu ?? onIdentity)(call) })
                #else
                .contextMenu {
                    Button("Show Profile") { (onIdentityMenu ?? onIdentity)(call) }
                    Button("Quick Look") { onIdentity(call) }
                    Divider()
                    Button("Copy Callsign") { ClipboardWriter.copy(call) }
                }
                #endif
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows what is known about \(call)")
        } else {
            text
        }
    }

    // MARK: - Premium Styling Components
    
    /// Enhanced indicator bar with emphasis for system/error messages
    @ViewBuilder
    private var indicatorBar: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(indicatorBarColor)
            .frame(width: ConsoleTheme.indicatorBarWidth)
            .help(categoryTooltip)
    }
    
    /// Premium indicator color that emphasizes system/error messages
    private var indicatorBarColor: Color {
        switch line.kind {
        case .system:
            return Color.gray.opacity(ConsoleTheme.systemIndicatorOpacity)
        case .error:
            return Color.red.opacity(ConsoleTheme.errorIndicatorOpacity)
        case .packet:
            return categoryBorderColor  // Keep existing packet colors
        }
    }
    
    /// Premium background with subtle tint for system/error messages
    private var premiumBackground: Color {
        return ConsoleTheme.backgroundColor(for: line.kind)
    }

    /// Left border color based on message category (matches filter buttons)
    private var categoryBorderColor: Color {
        switch line.kind {
        case .error:
            return .red
        case .system:
            return .gray  // Matches SYS filter button
        case .packet:
            guard let messageType = line.messageType else { return .brown }
            switch messageType {
            case .id: return .blue         // Matches ID filter button
            case .beacon: return .green    // Matches BCN filter button
            case .mail: return .orange     // Matches MAIL filter button
            case .data: return .purple     // Actual content/data (the interesting stuff!)
            case .prompt: return .cyan     // Commands, prompts, session messages
            case .message: return .brown   // Unclassified/other
            }
        }
    }

    /// Tooltip describing the message category
    private var categoryTooltip: String {
        switch line.kind {
        case .error:
            return "Error: An error or warning message"
        case .system:
            return "System: Connection status or application notification"
        case .packet:
            guard let messageType = line.messageType else {
                return "Other: Unclassified packet"
            }
            switch messageType {
            case .id:
                return "ID: Station identification broadcast"
            case .beacon:
                return "Beacon: Periodic status broadcast"
            case .mail:
                return "Mail: Message notification"
            case .data:
                return "Data: Content being transferred"
            case .prompt:
                return "Command: Session control or prompt"
            case .message:
                return "Other: Unclassified packet"
            }
        }
    }

    // Note: rowBackground is now handled by premiumBackground
    // This property is kept for backward compatibility but should not be used
    private var rowBackground: Color {
        return premiumBackground
    }

    private var messageColor: Color {
        switch line.kind {
        case .system: return .secondary
        case .error: return .red
        case .packet: return .primary
        }
    }

    private func callsignColor(for callsign: String) -> Color {
        guard line.kind == .packet else { return messageColor }
        let hash = abs(callsign.hashValue)
        let hue = Double(hash % 256) / 255.0
        return Color(hue: hue, saturation: callsignSaturation, brightness: callsignBrightness)
    }
}

// MARK: - Supporting Views

/// Small icon indicating digipeater path, with tooltip showing full path
struct DigiPathIndicator: View {
    let paths: [[String]]

    private var tooltipText: String {
        if paths.count == 1 {
            return "via " + paths[0].joined(separator: " → ")
        } else {
            return paths.enumerated().map { index, path in
                "Path \(index + 1): " + path.joined(separator: " → ")
            }.joined(separator: "\n")
        }
    }

    var body: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 10))
            .foregroundStyle(.purple.opacity(0.7))
            .help(tooltipText)
    }
}

/// Badge showing number of duplicate receptions
struct DuplicateCountBadge: View {
    let count: Int
    let kind: ConsoleLine.Kind

    var body: some View {
        Text("+\(count)")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(kind == .error ? .red : .purple)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background((kind == .error ? Color.red : Color.purple).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(kind == .packet ? "Received \(count + 1) times via different paths (click to expand)" : "Occurred \(count + 1) times consecutively (click to expand)")
    }
}

/// Toggle button for filtering message types
/// One switch on the console's filter row.
///
/// Plain click toggles. Option-click *solos* — shows this class and nothing
/// else — because isolating one type by switching off the other seven was
/// eight gestures to answer one question. Option-clicking a soloed chip puts
/// everything back.
///
/// The same two actions are in the right-click menu, because a modifier
/// nobody knows about is a feature nobody has.
struct FilterToggle: View {
    let label: String
    @Binding var isOn: Bool
    let color: Color
    var tooltip: String = ""
    /// Whether this chip is the only one showing.
    var isSoloed: Bool = false
    /// Show only this class. Nil leaves the chip a plain toggle.
    var onSolo: (() -> Void)?
    var onShowAll: (() -> Void)?

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(isOn ? color.opacity(isSoloed ? 0.35 : 0.2) : Color.gray.opacity(0.1))
            .foregroundStyle(isOn ? color : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            // A soloed chip is doing something the other seven are not, and
            // "lit" alone does not distinguish "on" from "the only one on".
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color, lineWidth: isSoloed ? 1 : 0))
            .contentShape(Rectangle())
            .modifier(SoloTapGesture(isSoloed: isSoloed,
                                     onToggle: { isOn.toggle() },
                                     onSolo: onSolo,
                                     onShowAll: onShowAll))
            .contextMenu {
                if let onSolo, let onShowAll {
                    if isSoloed {
                        Button("Show All Types") { onShowAll() }
                    } else {
                        Button("Show Only \(label)") { onSolo() }
                    }
                    Divider()
                }
                Toggle("Show \(label)", isOn: $isOn)
            }
            .help(onSolo == nil ? tooltip
                  : tooltip + "\n\nOption-click to show only this type.")
    }
}

/// Option-click means "solo"; a plain click still toggles.
///
/// `TapGesture().modifiers(_:)` is macOS-only, so on iOS the chip stays a
/// plain toggle and the menu carries the solo action instead.
private struct SoloTapGesture: ViewModifier {
    let isSoloed: Bool
    let onToggle: () -> Void
    let onSolo: (() -> Void)?
    let onShowAll: (() -> Void)?

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .highPriorityGesture(TapGesture().modifiers(.option).onEnded {
                guard let onSolo, let onShowAll else { return onToggle() }
                isSoloed ? onShowAll() : onSolo()
            })
            .onTapGesture(perform: onToggle)
        #else
        content.onTapGesture(perform: onToggle)
        #endif
    }
}

nonisolated private struct ConsoleScrollBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
