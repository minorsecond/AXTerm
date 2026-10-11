import Foundation

/// What the Packet Node page says at the top: what is on the air now, and
/// the services that are off in one line (park rehearsal 2026-10-08,
/// finding 46). Only enabled radios carry anything; a switched-off radio
/// folds to one line on the page.
nonisolated struct PacketNodeSummary: Equatable, Sendable {
    /// One line per service on the air, with the radios that carry it.
    let on: [String]
    /// The services that are off, or nil when none is.
    let off: String?

    init(radios: [RadioProfile], nodeRuns: Bool, announces: Bool, alias: String,
         pings: Bool, mailboxOnAir: Bool?) {
        let live = Self.shown(radios).filter { $0.runsPacketServices }
        func names(_ carries: (RadioProfile) -> Bool) -> String? {
            let carrying = live.filter(carries).map(RadioDetailView.title(for:))
            return carrying.isEmpty ? nil : carrying.joined(separator: ", ")
        }
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        let node = "Node " + (trimmedAlias.isEmpty ? "(no alias)" : trimmedAlias)

        var on: [String] = []
        var off: [String] = []

        switch (nodeRuns, announces) {
        case (false, false):
            off.append("node")
        case (true, false):
            on.append("\(node) answers callers")
        case (let runs, true):
            let carriers = names { $0.announcesNode } ?? "no radio"
            on.append("\(node) \(runs ? "answers callers and " : "")announces on \(carriers)")
        }

        if let mailboxOnAir {
            if mailboxOnAir, let carriers = names({ $0.answersMailbox }) {
                on.append("Mailbox answers on \(carriers)")
            } else {
                off.append("mailbox")
            }
        }

        if pings, let carriers = names({ $0.pings }) {
            on.append("Pings stations on \(carriers)")
        } else {
            off.append("ping")
        }
        if let carriers = names({ $0.digi.enabled }) {
            on.append("Digipeats on \(carriers)")
        } else {
            off.append("digipeater")
        }
        if let carriers = names({ $0.beacon.enabled }) {
            on.append("ID beacon on \(carriers)")
        } else {
            off.append("ID beacon")
        }

        self.on = on
        self.off = off.isEmpty ? nil : Self.sentence(off)
    }

    /// "Ping, digipeater and ID beacon are off."
    private static func sentence(_ items: [String]) -> String {
        let list: String
        switch items.count {
        case 1: list = items[0]
        case 2: list = "\(items[0]) and \(items[1])"
        default: list = items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
        return list.prefix(1).uppercased() + list.dropFirst() + (items.count == 1 ? " is off." : " are off.")
    }

    /// The radios the page shows in full: those switched on.
    static func shown(_ radios: [RadioProfile]) -> [RadioProfile] {
        radios.filter { !$0.archived && $0.enabled }
    }

    /// The radios folded to one line: switched off, so carrying nothing.
    static func folded(_ radios: [RadioProfile]) -> [RadioProfile] {
        radios.filter { !$0.archived && !$0.enabled }
    }
}
