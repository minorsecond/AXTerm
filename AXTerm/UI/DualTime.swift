import Foundation

/// When something was sent or received, in local time and in UTC
/// (operator, 2026-10-07). Radio logs and other stations run on UTC; the
/// operator's own day runs on local time. Every list of files and messages
/// shows both, the same way.
nonisolated enum DualTime {
    /// "Oct 7, 2026 at 2:41 PM", the operator's own clock.
    static func local(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// "20:41 UTC", or "Oct 8 02:15 UTC" when UTC has already moved on to
    /// another day than the local clock shows.
    static func utc(_ date: Date, localTimeZone: TimeZone = .current) -> String {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = localTimeZone
        var zulu = Calendar(identifier: .gregorian)
        zulu.timeZone = utcZone
        let sameDay = local.dateComponents([.year, .month, .day], from: date)
            == zulu.dateComponents([.year, .month, .day], from: date)
        return (sameDay ? timeOnly : dayAndTime).string(from: date) + " UTC"
    }

    /// Short, for a chat bubble: "2:41 PM · 20:41 UTC" today, with the date
    /// in front on any other day.
    static func compact(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current,
                        locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var style = calendar.isDate(date, inSameDayAs: now)
            ? Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
            : Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
        style.timeZone = timeZone
        return date.formatted(style) + " · " + utc(date, localTimeZone: timeZone)
    }

    /// Both on one line, for a row.
    static func line(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        local(date, timeZone: timeZone, locale: locale) + " · " + utc(date, localTimeZone: timeZone)
    }

    /// Both to the second, for a tooltip or a detail view.
    static func help(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .complete, time: .complete, locale: locale)
        style.timeZone = timeZone
        return date.formatted(style) + "\n" + full.string(from: date) + " UTC"
    }

    private static let utcZone = TimeZone(identifier: "UTC")!

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utcZone
        formatter.dateFormat = format
        return formatter
    }

    // DateFormatter is safe to share for formatting once configured.
    nonisolated(unsafe) private static let timeOnly = formatter("HH:mm")
    nonisolated(unsafe) private static let dayAndTime = formatter("MMM d HH:mm")
    nonisolated(unsafe) private static let full = formatter("yyyy-MM-dd HH:mm:ss")
}
