//
//  BBSMessage.swift
//  AXTerm
//
//  A message in the personal mailbox, and the rules for who may see it.
//

import Foundation

/// A message in the personal mailbox.
///
/// Bulletins are deliberately **not** a separate kind. A bulletin is a message
/// addressed to `BBSMessage.allCall`, which keeps visibility (`isReadable`) a
/// single comparison instead of a table of kinds crossed with a table of
/// audiences. That crossing is exactly where mailbox software historically
/// leaks private mail: every new kind is another chance to forget a case.
nonisolated struct BBSMessage: Equatable, Sendable, Identifiable {

    /// The address bulletins are sent to. Everything else is a callsign.
    static let allCall = "ALL"

    var id: Int64
    var from: String
    var to: String
    var subject: String
    var body: String
    var receivedAt: Date

    /// When the recipient read it. Nil while unread.
    ///
    /// The same fact whether they read it over the air or in this app: both
    /// are the addressee reading their own mail. Only meaningful for
    /// personally addressed mail — a bulletin has many readers and one flag
    /// cannot describe them, so reading one never sets this.
    var readAt: Date?

    /// Set by the `K` command. The row is never deleted: mail is append-only
    /// (CLAUDE.md §7), so killing the wrong number stays recoverable from the
    /// app's own UI.
    var killedAt: Date?

    var isBulletin: Bool { BBSMessage.baseCall(to) == BBSMessage.allCall }
}

extension BBSMessage {

    /// Mail is addressed to an operator, not to a radio: someone calling in as
    /// `K0XYZ-7` collects mail addressed to `K0XYZ`.
    ///
    /// Every real mailbox works this way, and it is not politeness — a sender
    /// has no way to discover which SSID the recipient will next call from, so
    /// matching the full address would strand mail that was correctly sent.
    static func baseCall(_ callsign: String) -> String {
        let trimmed = callsign.trimmingCharacters(in: .whitespaces).uppercased()
        guard let dash = trimmed.firstIndex(of: "-") else { return trimmed }
        return String(trimmed[trimmed.startIndex..<dash])
    }

    /// Addressed to this caller personally — bulletins do not count.
    func isAddressed(to caller: String) -> Bool {
        !isBulletin && BBSMessage.baseCall(to) == BBSMessage.baseCall(caller)
    }

    /// **The entire access model.** A caller sees a live message when it is
    /// addressed to them or to everyone.
    ///
    /// Kept as one expression on purpose: this is the only thing standing
    /// between a caller and the sysop's private mail, and it should be
    /// checkable at a glance by someone who does not trust it.
    func isReadable(by caller: String) -> Bool {
        killedAt == nil && (isBulletin || isAddressed(to: caller))
    }

    /// A caller may kill their own mail and messages they wrote — including a
    /// bulletin they posted. They may not kill someone else's bulletin, which
    /// would let any caller silently remove a notice for everybody.
    func isKillable(by caller: String) -> Bool {
        guard killedAt == nil else { return false }
        if BBSMessage.baseCall(from) == BBSMessage.baseCall(caller) { return true }
        return isAddressed(to: caller)
    }
}
