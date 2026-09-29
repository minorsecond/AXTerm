//
//  BBSMailboxModels.swift
//  AXTerm
//
//  The decisions the mailbox UI makes, separated from the views that draw
//  them.
//

import Foundation

// Nothing here is a view, and nothing here is guarded to a platform. The Mac
// panes and the iOS screens are two layouts of one mailbox, and the wording a
// caller-facing product lives or dies by — "looked around, left nothing", the
// airtime a file costs, which messages count as yours — must not be written
// twice and drift. It is also the only way any of it can be tested: the test
// bundle builds for macOS alone, so a rule sealed inside `#if os(iOS)` is a
// rule nothing can check.

// MARK: - Presentation

/// How `BBSScreen` is being shown, which decides whether it brings its own
/// navigation.
///
/// A view cannot ask "am I inside a navigation stack" — SwiftUI does not
/// answer that — and guessing wrong is not a small mistake: a
/// `NavigationSplitView` inside a stack renders one squeezed column with two
/// navigation bars, and a stack inside a stack doubles the back button. So the
/// shell states it, and the two placements are named rather than inferred.
nonisolated enum BBSScreenPresentation: Sendable, Equatable, CaseIterable {
    /// A tab's content: the mailbox owns its navigation and lays itself out as
    /// a `NavigationSplitView`, which collapses to a stack on a phone.
    case tab
    /// A row pushed inside a `NavigationStack` the shell owns — the compact
    /// "More" list. No split view, no stack of its own.
    case pushed

    /// Whether this placement brings its own navigation container.
    var ownsNavigation: Bool { self == .tab }
}

/// One row of the mailbox's own navigation — the four panes and their badges.
nonisolated struct BBSPaneRow: Equatable, Sendable, Identifiable {
    var pane: BBSPane
    /// Nil draws nothing. Zero is not a number worth printing beside a name.
    var badge: Int?

    var id: String { pane.rawValue }
}

nonisolated enum BBSPaneList {

    /// The four panes, in order, with the badges that apply.
    ///
    /// Only counts that change on their own are worth a badge. Directory and
    /// Files hold what the operator put there, so a number beside them would
    /// be decoration that never moves — and a badge that never moves teaches
    /// the operator to stop reading badges.
    ///
    /// - Parameters:
    ///   - messageBadge: what the caller counts as worth flagging. The iOS
    ///     screen passes unread mail; the Mac sidebar passes the message
    ///     count it has always shown.
    ///   - liveCallers: callers connected right now.
    static func rows(messageBadge: Int, liveCallers: Int) -> [BBSPaneRow] {
        BBSPane.allCases.map { pane in
            switch pane {
            case .messages:
                BBSPaneRow(pane: pane, badge: messageBadge > 0 ? messageBadge : nil)
            case .callers:
                BBSPaneRow(pane: pane, badge: liveCallers > 0 ? liveCallers : nil)
            case .directory, .files:
                BBSPaneRow(pane: pane, badge: nil)
            }
        }
    }
}

// MARK: - Messages

/// Which slice of the mailbox the operator is looking at.
///
/// Top level rather than nested in a pane, because both platforms' message
/// lists offer the same four and the empty-state wording belongs with the
/// filter that produces it.
nonisolated enum BBSMessageFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case mine = "Mine"
    case bulletins = "Bulletins"
    case all = "All"
    case killed = "Killed"

    var id: String { rawValue }
    var label: String { rawValue }

    var systemImage: String {
        switch self {
        case .mine: "tray.full"
        case .bulletins: "megaphone"
        case .all: "tray.2"
        case .killed: "trash"
        }
    }

    var emptyTitle: String {
        switch self {
        case .mine: "No mail for you"
        case .bulletins: "No bulletins"
        case .all: "Mailbox empty"
        case .killed: "Nothing killed"
        }
    }

    /// Says what would put something here, which an empty list otherwise
    /// leaves the operator to guess.
    func emptyDetail(sysop: String) -> String {
        switch self {
        case .mine: "Callers leave mail with S \(sysop) at the prompt."
        case .bulletins: "Post one with New Message addressed to ALL — every caller can read it."
        case .all: "Nothing has been left here yet."
        case .killed: "Killed messages stay here so a mistaken K can be undone."
        }
    }
}

/// What the operator's message list shows, and which rows are unread.
nonisolated enum BBSMessageList {

    /// The messages a filter selects, newest first.
    ///
    /// "Mine" is deliberately `isAddressed(to:)` rather than "not a bulletin
    /// addressed to something like us": addressing is by base callsign
    /// (`BBSMessage.baseCall`), so mail left for `K0EPI` is the sysop's
    /// whether the mailbox answers as `K0EPI-2` or not. Bulletins are excluded
    /// from it for the same reason they are excluded from `isAddressed` — a
    /// notice to everybody is not mail for anybody.
    ///
    /// Every filter but Killed hides killed messages, because a killed message
    /// is hidden from callers and showing it under "All" would make the two
    /// views of the mailbox disagree about what is in it.
    static func visible(_ messages: [BBSMessage],
                        filter: BBSMessageFilter,
                        sysop: String) -> [BBSMessage] {
        let filtered: [BBSMessage] = switch filter {
        case .mine: messages.filter { $0.killedAt == nil && $0.isAddressed(to: sysop) }
        case .bulletins: messages.filter { $0.killedAt == nil && $0.isBulletin }
        case .all: messages.filter { $0.killedAt == nil }
        case .killed: messages.filter { $0.killedAt != nil }
        }
        return filtered.sorted { $0.receivedAt > $1.receivedAt }
    }

    /// Unread means *unread by the sysop*, so only their own mail can be it.
    ///
    /// A bulletin has many readers and one flag cannot describe them
    /// (`BBSMessage.readAt`), so a bulletin is never drawn unread — otherwise
    /// the mailbox would carry a badge nothing could ever clear.
    static func isUnread(_ message: BBSMessage, sysop: String) -> Bool {
        message.readAt == nil && message.isAddressed(to: sysop)
    }

    static func unreadCount(_ messages: [BBSMessage], sysop: String) -> Int {
        messages.filter { $0.killedAt == nil && isUnread($0, sysop: sysop) }.count
    }

    /// Whether opening this message in the app should mark it read.
    ///
    /// Reading your own mail in the app is the same fact as reading it over
    /// the air — see `BBSMessage.readAt` — and nothing else is the sysop's to
    /// mark.
    static func shouldMarkRead(_ message: BBSMessage, sysop: String) -> Bool {
        message.readAt == nil && message.isAddressed(to: sysop)
    }

    /// The subject as a row shows it. An empty subject is a real thing a
    /// caller can send, and a blank row reads as a drawing bug.
    static func subjectLabel(_ message: BBSMessage) -> String {
        let trimmed = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no subject)" : trimmed
    }
}

// MARK: - Other mailboxes

/// What the mailbox screens may do with a row, and what they say about it,
/// once other instances are in the list.
///
/// The whole point of the unified view is that it is *attributed, never
/// merged*. A message the home rig's mailbox took is a fact about that
/// mailbox: its number belongs to that mailbox's numbering, its read flag and
/// its kill flag are that mailbox's append-only history, and this device
/// editing either would be inventing a state the mailbox that made the promise
/// knows nothing about. So a remote row is readable and nothing else.
nonisolated enum BBSRemoteMailbox {

    /// The chip's label. "Mailboxes" rather than "devices", because what is
    /// being brought in is another *mailbox* — a device may run none.
    static let toggleTitle = "Other mailboxes"

    static let toggleHint = "Also lists messages and callers from your other devices\u{2019} "
        + "mailboxes, under each mailbox\u{2019}s own heading"

    /// Said on the attribution line under a remote heading rather than on the
    /// chip: `.explain` wraps what it decorates in a container of its own,
    /// which stops a `Toggle` responding to taps at all on iOS. It also
    /// belongs beside the rows it describes.
    static let attributionExplanation =
        "Messages and calls another of your devices\u{2019} mailboxes recorded, sent here "
        + "when that device has \u{201C}Share my packet mailbox\u{201D} switched on.\n\n"
        + "Nothing here is merged into this mailbox. Message numbers belong to the mailbox "
        + "that issued them \u{2014} two mailboxes can both hold a \u{201C}Message 12\u{201D} "
        + "and they are different messages \u{2014} and the callers log stays that station\u{2019}s "
        + "log. Rows from elsewhere are read-only: reading one marks nothing, and it cannot be "
        + "killed or restored from here, because that history belongs to the mailbox that made it."

    /// Under a remote message's header.
    static let readOnlyNote = "Recorded by that mailbox; read-only here."

    /// Whether to offer the chip at all.
    ///
    /// Only with somewhere to read from, and only once something has arrived
    /// — or while it is already on, so switching it off is always possible. A
    /// control for data that has never arrived is a promise the screen cannot
    /// keep.
    static func showsToggle(hasStore: Bool, remoteCount: Int, isOn: Bool) -> Bool {
        hasStore && (remoteCount > 0 || isOn)
    }

    /// Whether remote rows are worth fetching at all this pass.
    ///
    /// Read whenever there is a store, not only while the chip is on: the
    /// chip only appears once something has arrived, so a build that fetched
    /// only when switched on could never discover it had anything to show.
    static func shouldLoadRemote(hasStore: Bool) -> Bool { hasStore }

    /// The banner over a message opened from another mailbox. Nil for a
    /// message this mailbox took, which needs no explaining.
    static func banner(for origin: BBSUnifiedListing.Origin) -> String? {
        guard let label = origin.label else { return nil }
        return "\(label). \(readOnlyNote)"
    }
}

/// What a message row lets the operator do.
///
/// Derived from where the message came from rather than checked at each
/// button, so a new surface cannot quietly offer Kill on somebody else's
/// mailbox by forgetting a condition.
nonisolated struct BBSMessageActions: Equatable, Sendable {
    /// Replying is always allowed, including from another mailbox's message:
    /// the reply is composed *here*, in this mailbox, addressed to whoever
    /// wrote it. That writes nothing to the mailbox that took the original.
    var canReply: Bool
    var canKill: Bool
    var canRestore: Bool
    /// Whether opening it in the app should stamp `readAt`.
    var marksRead: Bool
    /// Whether the row draws the unread dot.
    ///
    /// Never for another mailbox. Its read flag is that station's record of
    /// what its operator did there, and nothing this device does can clear it
    /// — a dot that cannot be dismissed is a badge that teaches the operator
    /// to stop reading badges.
    var showsUnread: Bool

    /// True when the row offers nothing that changes anything.
    var isReadOnly: Bool { !canKill && !canRestore && !marksRead }

    static func forRow(message: BBSMessage,
                       origin: BBSUnifiedListing.Origin,
                       sysop: String) -> BBSMessageActions {
        let canReply = !message.from.trimmingCharacters(in: .whitespaces).isEmpty
        guard origin == .thisMailbox else {
            return BBSMessageActions(canReply: canReply, canKill: false,
                                     canRestore: false, marksRead: false,
                                     showsUnread: false)
        }
        return BBSMessageActions(
            canReply: canReply,
            canKill: message.killedAt == nil,
            canRestore: message.killedAt != nil,
            marksRead: BBSMessageList.shouldMarkRead(message, sysop: sysop),
            showsUnread: BBSMessageList.isUnread(message, sysop: sysop))
    }
}

// MARK: - Durations

/// Call durations, in the one format the whole mailbox uses.
///
/// Hoisted out of `BBSLiveCallPanel` because the callers log needs it too and
/// a view is not a place to keep a formatter — and because on iOS the live
/// panel and the log are on different screens.
nonisolated enum BBSElapsed {

    /// `m:ss`, counting up. Deliberately not `DateComponentsFormatter`: a call
    /// is read at a glance against the transcript scrolling beside it, and
    /// "3:07" is that glance where "3 minutes, 7 seconds" is a sentence.
    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func format(from start: Date, to end: Date) -> String {
        format(end.timeIntervalSince(start))
    }
}

// MARK: - Callers

/// One row of the callers log.
///
/// The operator is asleep for most of what the mailbox does, so this row is
/// the whole answer to "what happened overnight" — and a caller who read a
/// bulletin and left nothing behind has to be as visible here as one who left
/// mail, because they are invisible everywhere else.
nonisolated struct BBSCallRowModel: Equatable, Sendable {
    var callsign: String
    var isLive: Bool
    /// `m:ss`, empty only when a finished call somehow has no end time.
    var duration: String
    /// What they did, in order. Never empty: a call with no actions says so.
    var summary: [String]
    /// Whether the row says the actions are all there was.
    var didNothing: Bool
    /// A caller who said `B` got what they came for; one whose link dropped
    /// may not have, and that is the difference worth a marker.
    var showsLinkDropped: Bool

    static func make(_ call: BBSCall, now: Date) -> BBSCallRowModel {
        let duration: String
        if call.isLive {
            duration = BBSElapsed.format(from: call.connectedAt, to: now)
        } else if let seconds = call.duration {
            duration = BBSElapsed.format(seconds)
        } else {
            duration = ""
        }

        let didNothing = call.actions.isEmpty
        return BBSCallRowModel(
            callsign: call.callsign,
            isLive: call.isLive,
            duration: duration,
            summary: didNothing
                ? [call.isLive ? "connected" : "looked around, left nothing"]
                : call.actions,
            didNothing: didNothing,
            showsLinkDropped: call.endedUnexpectedly && !call.isLive)
    }
}

// MARK: - Files

/// One row of the file catalogue, in the operator's view.
///
/// The same two figures the shell quotes callers, computed the same way, so
/// what the operator reads and what goes out on the air cannot disagree.
nonisolated struct BBSFileRowModel: Equatable, Sendable {
    var name: String
    var isText: Bool
    var size: String
    /// How long it takes on the air — the number that actually decides whether
    /// a caller should ask for the file at all.
    var airtime: String
    /// Long enough to be worth flagging. Matches the shell's own confirmation
    /// threshold, so a file the operator sees marked is exactly the file a
    /// caller is asked to confirm.
    var isLongTransfer: Bool
    /// Empty when the operator has not written one. A filename alone tells a
    /// caller nothing, and on this link they cannot download one to find out.
    var about: String

    /// Fifteen minutes. `BBSShell.longTransferSeconds` defaults to five, which
    /// is the point at which a *caller* is asked to confirm; this is the point
    /// at which the operator's own catalogue starts warning them, and it is
    /// deliberately looser — every row past five minutes painted orange would
    /// mark most of a real file area and stop meaning anything.
    static let longTransferSeconds: Double = 900

    static func make(_ file: BBSSharedFile, bytesPerSecond: Double) -> BBSFileRowModel {
        // No throughput figure means no estimate. `BBSFileIndex.duration`
        // already answers "?" here; claiming a transfer is long on the
        // strength of a division by zero would be worse than saying nothing.
        let seconds = bytesPerSecond > 0 ? Double(file.byteCount) / bytesPerSecond : 0
        return BBSFileRowModel(
            name: file.name,
            isText: file.isText,
            size: BBSFileIndex.size(file.byteCount),
            airtime: BBSFileIndex.duration(bytes: file.byteCount,
                                           bytesPerSecond: bytesPerSecond),
            isLongTransfer: seconds > longTransferSeconds,
            about: file.about)
    }
}

/// One row of the area list.
nonisolated struct BBSAreaRowModel: Equatable, Sendable {
    var name: String
    var about: String
    var fileCount: Int
    /// "3 files · 147K" — the count and the total, because an area is chosen
    /// by whether it is worth the airtime to list.
    var subtitle: String

    static func make(_ area: BBSFileArea, files: [BBSSharedFile]) -> BBSAreaRowModel {
        let bytes = files.reduce(0) { $0 + $1.byteCount }
        return BBSAreaRowModel(
            name: area.name,
            about: area.about,
            fileCount: files.count,
            subtitle: "\(files.count) file\(files.count == 1 ? "" : "s") · "
                + BBSFileIndex.size(bytes))
    }
}

/// The sizes an operator may cap uploads at.
///
/// A short list rather than a number field: the decision is "how much of the
/// channel am I prepared to give a stranger", and four round answers make that
/// choice legible where a byte count does not.
nonisolated struct BBSUploadSizeOption: Identifiable, Hashable, Sendable {
    let bytes: Int
    let label: String

    var id: Int { bytes }

    static let standard: [BBSUploadSizeOption] = [
        BBSUploadSizeOption(bytes: 50 * 1024, label: "50K"),
        BBSUploadSizeOption(bytes: 100 * 1024, label: "100K"),
        BBSUploadSizeOption(bytes: 500 * 1024, label: "500K"),
        BBSUploadSizeOption(bytes: 2 * 1024 * 1024, label: "2M")
    ]

    /// The list, guaranteed to contain the value currently stored.
    ///
    /// A SwiftUI `Picker` whose selection matches no tag draws blank and
    /// silently rewrites nothing — the operator sees an empty control and, on
    /// touching it, changes a limit they never meant to. A stored value from
    /// an older build or another device therefore joins the list rather than
    /// disappearing from it.
    static func options(including bytes: Int) -> [BBSUploadSizeOption] {
        guard bytes > 0, !standard.contains(where: { $0.bytes == bytes }) else {
            return standard
        }
        let extra = BBSUploadSizeOption(bytes: bytes, label: BBSFileIndex.size(bytes))
        return (standard + [extra]).sorted { $0.bytes < $1.bytes }
    }
}

/// The upload inbox, as one line the operator can read at a glance.
///
/// The quota is the bound that stops an unattended station filling a disk on
/// the say-so of strangers, and it is invisible until it bites — an operator
/// whose uploads suddenly start being refused has no way to tell that from a
/// broken transfer. So it is stated with the usage, always, rather than
/// surfaced as an error after the fact.
nonisolated struct BBSUploadInboxModel: Equatable, Sendable {
    /// "3 files · 1.2M of 20M"
    var label: String
    /// Whether the next upload will be refused for space.
    var isFull: Bool

    static func make(count: Int, bytes: Int, quotaBytes: Int) -> BBSUploadInboxModel {
        let files = "\(count) file\(count == 1 ? "" : "s")"
        // A quota of zero or less is not a quota. Printing "of 0B" would say
        // the inbox is permanently full when in fact nothing is capping it.
        let used = quotaBytes > 0
            ? "\(BBSFileIndex.size(bytes)) of \(BBSFileIndex.size(quotaBytes))"
            : BBSFileIndex.size(bytes)
        return BBSUploadInboxModel(label: "\(files) · \(used)",
                                   isFull: quotaBytes > 0 && bytes >= quotaBytes)
    }
}

// MARK: - Directory

/// How this station knows one field of a directory entry, in words.
///
/// Provenance is on the face of the row rather than in a tooltip, because it
/// is what decides whether an entry can be trusted: a name someone typed at
/// the prompt and a home BBS guessed from a message header look identical once
/// you write them both down as text.
nonisolated enum BBSDirectoryProvenance {

    /// "told to this station · with NQ on 3 Jan 2026", or the same without the
    /// command for anything nobody typed.
    ///
    /// The command is named only for `selfReported`. "Set by NQ" beside a
    /// licence lookup names a command nobody ran.
    static func caption(key: WhitePagesEntry.Key,
                        field: WhitePagesEntry.Field) -> String {
        let when = field.updatedAt.formatted(date: .abbreviated, time: .omitted)
        return field.source == .selfReported
            ? "\(field.source.explanation) · with \(key.command) on \(when)"
            : "\(field.source.explanation) · \(when)"
    }

    /// The glyph beside it: a quote for testimony, a wand for anything worked
    /// out. Two states, because the question the operator is asking is only
    /// "did somebody tell us this".
    static func systemImage(for source: WhitePagesEntry.Source) -> String {
        source == .selfReported ? "quote.bubble" : "wand.and.stars"
    }
}

/// One row of the directory list.
nonisolated struct BBSDirectoryRowModel: Equatable, Sendable {
    var callsign: String
    /// The name, or a statement that there is not one — never blank, because a
    /// blank second line reads as a rendering fault rather than as an absence.
    var subtitle: String
    var hasName: Bool

    static func make(_ entry: WhitePagesEntry) -> BBSDirectoryRowModel {
        let name = entry.value(.name)
        return BBSDirectoryRowModel(
            callsign: entry.callsign,
            subtitle: name ?? "no name on file",
            hasName: name != nil)
    }
}

/// Harvested facts waiting to be accepted, arranged for review.
nonisolated enum BBSDirectorySuggestions {

    /// One group per callsign, so an operator judging a parse sees everything
    /// claimed about one person at once rather than four unrelated rows.
    ///
    /// Callsigns come out in first-seen order rather than sorted: the
    /// harvester emits them in the order they appeared in the session the
    /// operator just had, and that order is itself evidence — it is the shape
    /// of the listing they were reading.
    struct Group: Identifiable, Equatable, Sendable {
        var callsign: String
        var candidates: [BBSDirectoryHarvester.Candidate]
        var id: String { callsign }
    }

    static func grouped(_ candidates: [BBSDirectoryHarvester.Candidate]) -> [Group] {
        var order: [String] = []
        var byCallsign: [String: [BBSDirectoryHarvester.Candidate]] = [:]
        for candidate in candidates {
            if byCallsign[candidate.callsign] == nil { order.append(candidate.callsign) }
            byCallsign[candidate.callsign, default: []].append(candidate)
        }
        return order.map { Group(callsign: $0, candidates: byCallsign[$0] ?? []) }
    }

    /// "3 spotted in BBS sessions" — the banner's own headline.
    static func headline(_ candidates: [BBSDirectoryHarvester.Candidate]) -> String {
        "\(candidates.count) spotted in BBS sessions"
    }
}

// MARK: - Settings preview

/// What a caller sees on connect, assembled by the real shell.
///
/// Built by `BBSShell` rather than by a mock-up of it, so the preview cannot
/// drift away from what is transmitted. The operator writing a banner blind
/// has no way to judge it; the whole value of the preview is that it is not a
/// separate rendering of the same idea.
nonisolated enum BBSGreetingPreview {

    /// The caller in the preview. A stranger rather than the operator: a
    /// station this mailbox has met is greeted by name, and previewing that
    /// would show a line most callers never see.
    static let previewCaller = "W0ARP"

    static func lines(sysop: String, banner: String, now: Date = Date()) -> [String] {
        var shell = BBSShell(caller: previewCaller, sysop: sysop, banner: banner)
        var lines = shell.greeting(mailbox: BBSShell.Mailbox(), now: now).lines
        lines.append(BBSShell.commandPrompt)
        return lines
    }
}
