import Foundation

/// ICS-309 Communications Log.
///
/// Every formal activation ends with someone asking for the message log,
/// and unlike almost everything else an operator does, this one cannot be
/// reconstructed afterwards — either the traffic was recorded as it
/// happened or it is gone. AXTerm already stores every message with its
/// time, correspondent, and subject, so the log is a report over data on
/// hand rather than a new thing to maintain.
///
/// The form is faithful to ICS-309: an incident name, an operational
/// period, the operator and station identity, and a chronological table
/// of `DATE/TIME · FROM · TO · SUBJECT`. Times are rendered in **UTC**,
/// because that is what the traffic carries and what a served agency
/// receiving logs from several stations can actually reconcile.
nonisolated struct ICS309Log: Equatable, Sendable {

    struct Entry: Equatable, Sendable, Identifiable {
        var date: Date
        var from: String
        var to: String
        var subject: String
        /// The MID, kept so a log line can be traced back to the message.
        var mid: String
        var id: String { mid }
    }

    /// ICS-309 box 1.
    var incidentName: String
    /// ICS-309 box 2 — the operational period this log covers.
    var periodStart: Date
    var periodEnd: Date
    /// ICS-309 box 3: radio net name or task.
    var taskName: String
    /// ICS-309 box 4.
    var operatorName: String
    var stationId: String
    var entries: [Entry]

    /// Rows per printed page, matching the paper form. Used only for
    /// pagination in the rendered output.
    static let rowsPerPage = 30

    var pageCount: Int {
        max(1, Int((Double(entries.count) / Double(Self.rowsPerPage)).rounded(.up)))
    }

    // MARK: - Building

    /// Builds a log from stored message summaries.
    ///
    /// Only messages whose timestamp falls inside the operational period
    /// are included — a log that quietly spans a different window than
    /// its header claims is worse than no log. Entries are ordered
    /// oldest-first, and ties broken by MID so two runs over the same
    /// data produce byte-identical output.
    static func build(messages: [WinlinkMessageSummary],
                      incidentName: String,
                      periodStart: Date,
                      periodEnd: Date,
                      taskName: String,
                      operatorName: String,
                      stationId: String) -> ICS309Log {
        let station = stationId.uppercased()
        let entries = messages
            .filter { $0.date >= periodStart && $0.date <= periodEnd }
            .map { summary -> Entry in
                switch summary.direction {
                case .inbound:
                    return Entry(date: summary.date,
                                 from: summary.fromAddr.uppercased(),
                                 to: station,
                                 subject: summary.subject,
                                 mid: summary.mid)
                case .outbound:
                    return Entry(date: summary.date,
                                 from: station,
                                 // A message to several addresses is one
                                 // transmission, so it stays one row.
                                 to: summary.toAddrs.map { $0.uppercased() }
                                     .joined(separator: ", "),
                                 subject: summary.subject,
                                 mid: summary.mid)
                }
            }
            .sorted { ($0.date, $0.mid) < ($1.date, $1.mid) }

        return ICS309Log(
            incidentName: incidentName,
            periodStart: periodStart,
            periodEnd: periodEnd,
            taskName: taskName,
            operatorName: operatorName,
            stationId: station,
            entries: entries)
    }

    // MARK: - Rendering

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date) + "Z"
    }

    /// Fixed-width plain text — the form as it would be typed, and the
    /// shape that survives being pasted into a radiogram.
    func renderPlainText() -> String {
        var out = """
        ICS-309 COMMUNICATIONS LOG

        1. Incident Name: \(orDash(incidentName))
        2. Operational Period: \(Self.timestamp(periodStart)) to \(Self.timestamp(periodEnd))
        3. Radio Net Name / Task: \(orDash(taskName))
        4. Operator Name: \(orDash(operatorName))
           Station ID: \(orDash(stationId))

        """

        if entries.isEmpty {
            out += "\nNo traffic logged in this operational period.\n"
            return out
        }

        let fromWidth = max(12, entries.map(\.from.count).max() ?? 12)
        let toWidth = max(12, min(28, entries.map(\.to.count).max() ?? 12))

        out += "\n"
        out += pad("DATE/TIME (UTC)", 21) + pad("FROM", fromWidth + 2)
            + pad("TO", toWidth + 2) + "SUBJECT\n"
        out += String(repeating: "-", count: 21 + fromWidth + 2 + toWidth + 2 + 30) + "\n"

        for entry in entries {
            out += pad(Self.timestamp(entry.date), 21)
            out += pad(entry.from, fromWidth + 2)
            out += pad(entry.to, toWidth + 2)
            out += entry.subject.isEmpty ? "(no subject)" : entry.subject
            out += "\n"
        }

        out += "\n\(entries.count) message\(entries.count == 1 ? "" : "s") logged"
        out += " \u{00B7} page 1 of \(pageCount)\n"
        return out
    }

    /// CSV for spreadsheets and for agencies that ingest logs.
    func renderCSV() -> String {
        var rows = ["Date/Time (UTC),From,To,Subject,MID"]
        for entry in entries {
            rows.append([
                Self.timestamp(entry.date),
                entry.from,
                entry.to,
                entry.subject,
                entry.mid,
            ].map(Self.csvEscape).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180: quote a field containing a comma, quote, or newline, and
    /// double any embedded quotes. Message subjects routinely contain
    /// commas, so this is the difference between a valid log and a
    /// mangled one.
    static func csvEscape(_ field: String) -> String {
        let needsQuoting = field.contains(",") || field.contains("\"")
            || field.contains("\n") || field.contains("\r")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func orDash(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).isEmpty ? "\u{2014}" : value
    }

    private func pad(_ value: String, _ width: Int) -> String {
        value.count >= width
            ? String(value.prefix(width - 1)) + " "
            : value + String(repeating: " ", count: width - value.count)
    }
}
