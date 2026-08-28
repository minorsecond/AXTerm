import Foundation

/// How one message reads in the folder list.
///
/// Split out of the view so the wording is testable, and because the old row
/// showed every field a mail client *has* rather than the few it reads by:
/// a full "Aug 24, 2026 at 10:52 AM" stamp that truncated the sender beside
/// it, and a "Received" badge on every row of a folder where nothing else is
/// possible. Both cost attention and returned nothing.
nonisolated struct WinlinkMessageRowModel: Equatable {

    var correspondent: String
    var subject: String
    /// True when `subject` is the placeholder, so the view can grey it.
    var subjectIsPlaceholder: Bool
    /// Mail-client date: time today, "Yesterday", "Aug 24", "8/24/25".
    var dateLabel: String
    var sizeLabel: String
    var showsAttachmentIndicator: Bool
    var isUnread: Bool
    /// Nil when the state is what the folder already implies. A badge that
    /// appears on every row is furniture; one that appears on three rows is
    /// information.
    var badge: WinlinkMessageStateRecord.DeliveryState?

    static func make(_ summary: WinlinkMessageSummary,
                     now: Date = Date(),
                     calendar: Calendar = .current) -> WinlinkMessageRowModel {
        WinlinkMessageRowModel(
            correspondent: correspondent(of: summary),
            subject: summary.subject.isEmpty ? "(no subject)" : summary.subject,
            subjectIsPlaceholder: summary.subject.isEmpty,
            dateLabel: dateLabel(summary.date, now: now, calendar: calendar),
            sizeLabel: WinlinkExchangeStatus.compact(summary.bodySize),
            showsAttachmentIndicator: summary.attachmentCount > 0,
            isUnread: !summary.isRead,
            badge: badge(for: summary.deliveryState))
    }

    /// Who the row is *about* — the sender for inbound mail, the recipient
    /// for outbound, which is what every mail client shows.
    static func correspondent(of summary: WinlinkMessageSummary) -> String {
        let raw: String
        switch summary.direction {
        case .inbound: raw = summary.fromAddr
        case .outbound: raw = summary.toAddrs.first ?? "—"
        }
        return displayAddress(raw)
    }

    /// Strips Winlink's transport prefix from internet addresses.
    ///
    /// `SMTP:` marks how a message left the system, not who sent it, and it
    /// pushed the useful half of the address out of a one-line row.
    static func displayAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 5 else { return trimmed.isEmpty ? "—" : trimmed }
        if trimmed.uppercased().hasPrefix("SMTP:") {
            let rest = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? trimmed : rest
        }
        return trimmed
    }

    /// The convention every mail client shares: recent mail is placed by
    /// time of day, older mail by date, and the year only once it matters.
    ///
    /// "Today" means the same day as `now`, not the same day as the system
    /// clock. `isDateInToday`/`isDateInYesterday` ask the clock and ignore
    /// their calendar's reference point, so this took a `now` it then threw
    /// away — the label was right in the app (which passes the real date) and
    /// unpinnable in a test, which passed only on the day it was written.
    static func dateLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        // Formatted through the same calendar the comparisons use. Otherwise a
        // row can say "Yesterday" beside a time from the other side of
        // midnight, whenever the two disagree about the time zone.
        let style = Date.FormatStyle(
            locale: calendar.locale ?? .autoupdatingCurrent,
            calendar: calendar,
            timeZone: calendar.timeZone)

        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style.hour().minute())
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(style.month(.abbreviated).day())
        }
        return date.formatted(style.year(.twoDigits).month(.defaultDigits).day())
    }

    /// Only states that ask something of the operator, or warn them.
    ///
    /// `received` in the Inbox and `sent` in Sent describe the folder, not
    /// the message.
    static func badge(for state: WinlinkMessageStateRecord.DeliveryState)
        -> WinlinkMessageStateRecord.DeliveryState? {
        switch state {
        case .received, .sent: return nil
        case .draft, .queued, .sending, .failed: return state
        }
    }
}
