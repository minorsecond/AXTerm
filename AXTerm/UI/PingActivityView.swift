//
//  PingActivityView.swift
//  AXTerm
//
//  Every probe this station has put on the air, and what came back.
//
//  The Transmission settings pane shows the last eight probes, which
//  answers "is this thing running". It cannot answer the questions that
//  actually come up — which stations answer and which never do, how far
//  the round trips spread, whether a station stopped answering or was
//  never asked, how much of the channel this feature is using. Those need
//  the log, not the last line of it.
//
//  Restraint is the whole design of the prober, so the numbers that say
//  how much it transmitted belong somewhere an operator can find them.
//

import SwiftUI

struct PingActivityView: View {

    @ObservedObject var prober: PingProber
    /// Live, so the header can say what the current pacing allows rather
    /// than describing a policy the operator has since changed.
    @ObservedObject var settings: AppSettingsStore

    private enum Pane: String, CaseIterable, Identifiable {
        case stations = "Stations"
        case log = "Log"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .stations
    @State private var isConfirmingClear = false

    private var attempts: [PingProber.Attempt] { prober.attempts }
    private var summary: PingStatistics.Summary { PingStatistics.summary(attempts) }
    private var rows: [PingStatistics.StationRow] {
        PingStatistics.stations(attempts: attempts, records: prober.records)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryTiles
            activityStrip
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(16)
    }

    private var summaryTiles: some View {
        let stats = summary
        return HStack(alignment: .top, spacing: 20) {
            tile("Probes sent", value: "\(stats.completed + stats.waiting)",
                 caption: stats.waiting > 0 ? "\(stats.waiting) on the air" : coverageCaption(stats),
                 help: "Every probe in the log, which keeps the most recent "
                     + "\(PingProber.attemptLogLimit). Totals per station on the "
                     + "Stations tab count every probe ever sent, including ones "
                     + "older than the log.")
            tile("Answered", value: "\(stats.answered)",
                 caption: rateCaption(stats),
                 help: "An answer proves radio worked both ways at that moment — "
                     + "no more than that. It is not a route and not a promise "
                     + "to accept a call.")
            tile("Median latency", value: stats.medianRTT.map(Self.latency) ?? "\u{2014}",
                 caption: spreadCaption(stats),
                 help: "The middle round trip, not the average: a probe that "
                     + "landed while the channel was busy carries seconds of "
                     + "somebody else's traffic, and an average reports a "
                     + "number no probe measured.")
            tile("Stations", value: "\(rows.count)",
                 caption: pacingCaption(),
                 help: "Addresses probed. The pacing shown is what Transmission "
                     + "settings currently allow, not what produced this log.")
            Spacer(minLength: 0)
        }
    }

    private func tile(_ title: String, value: String,
                      caption: String?, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded))
                .monospacedDigit()
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .help(help)
    }

    private func coverageCaption(_ stats: PingStatistics.Summary) -> String? {
        guard let first = stats.firstProbe, let last = stats.lastProbe else { return nil }
        let days = max(1, Calendar.current.dateComponents(
            [.day], from: first, to: last).day.map { $0 + 1 } ?? 1)
        return days == 1 ? "today" : "over \(days) days"
    }

    private func rateCaption(_ stats: PingStatistics.Summary) -> String? {
        guard let rate = stats.answerRate else { return "nothing finished yet" }
        let percent = Int((rate * 100).rounded())
        guard stats.escalatedAnswers > 0 else { return "\(percent)% of \(stats.completed)" }
        return "\(percent)% of \(stats.completed) \u{b7} \(stats.escalatedAnswers) needed DISC"
    }

    private func spreadCaption(_ stats: PingStatistics.Summary) -> String? {
        guard let fastest = stats.fastestRTT, let slowest = stats.slowestRTT else { return nil }
        return "\(Self.latency(fastest)) \u{2013} \(Self.latency(slowest))"
    }

    private func pacingCaption() -> String? {
        guard settings.pingEnabled else { return "pinging is off" }
        let box = settings.pingBoxCooldownMinutes
        guard box > 0 else { return "each SSID paced alone" }
        return "one per station per "
            + IntervalFormat.label(seconds: box * 60).lowercased()
    }

    /// Twenty-four hours of probing, answered against silent.
    ///
    /// A bar chart of two numbers per hour would be a chart library and a
    /// legend; this is the same information as height and colour, which is
    /// all the question needs — when did this station transmit, and did
    /// anyone answer.
    private var activityStrip: some View {
        let buckets = PingStatistics.hourly(attempts, now: Date())
        let peak = max(1, buckets.map(\.probes).max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(buckets) { bucket in
                    VStack(spacing: 1) {
                        Spacer(minLength: 0)
                        if bucket.silent > 0 {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.35))
                                .frame(height: barHeight(bucket.silent, peak: peak))
                        }
                        if bucket.answered > 0 {
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(height: barHeight(bucket.answered, peak: peak))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .help(Self.bucketHelp(bucket))
                }
            }
            .frame(height: 34)
            HStack {
                Text("24 hours")
                Spacer()
                Label("answered", systemImage: "square.fill")
                    .foregroundStyle(Color.accentColor)
                Label("no answer", systemImage: "square.fill")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Probes per hour over the last day")
    }

    private func barHeight(_ count: Int, peak: Int) -> CGFloat {
        max(2, CGFloat(count) / CGFloat(peak) * 30)
    }

    // MARK: - Panes

    @ViewBuilder
    private var content: some View {
        if attempts.isEmpty && rows.isEmpty {
            ContentUnavailableView(
                "No probes yet",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text(settings.pingEnabled
                    ? "Pinging is on. Probes appear here as they go out."
                    : "Pinging is off. Turn it on in Settings \u{2192} Transmission, "
                        + "or ping a station by hand from its profile."))
        } else {
            switch pane {
            case .stations: stationList
            case .log: logList
            }
        }
    }

    private var stationList: some View {
        // Rows built by hand rather than with `Table`: this window opens on
        // iPad too, where Table renders as an unusable single column.
        ScrollView {
            LazyVStack(spacing: 0) {
                stationHeaderRow
                ForEach(rows) { row in
                    Divider()
                    stationRow(row)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var stationHeaderRow: some View {
        HStack(spacing: 12) {
            Text("Station").frame(width: 110, alignment: .leading)
            Text("Probes").frame(width: 60, alignment: .trailing)
            Text("Answered").frame(width: 80, alignment: .trailing)
            Text("Median").frame(width: 70, alignment: .trailing)
            Text("Last answer").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    private func stationRow(_ row: PingStatistics.StationRow) -> some View {
        HStack(spacing: 12) {
            Text(row.call)
                .font(.system(.body, design: .monospaced))
                .frame(width: 110, alignment: .leading)
            Text("\(row.probes)")
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
            Text(row.answerRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "\u{2014}")
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(row.answered == 0 ? .secondary : .primary)
                .help(row.answered == 0
                      ? "\(row.probes) probes, no answer."
                      : "\(row.answered) answered of \(row.answered + row.silent) finished.")
            Text(row.medianRTT.map(Self.latency) ?? "\u{2014}")
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(Self.lastAnswerDescription(row))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(Self.stationHelp(row))
    }

    private var logList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Newest first: the question asked of a log is almost
                // always "what just happened".
                ForEach(attempts.reversed()) { attempt in
                    Divider()
                    HStack(spacing: 12) {
                        Text(Self.stamp(attempt.sentAt))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .leading)
                        Text(attempt.call)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 110, alignment: .leading)
                        Text(Self.outcomeDescription(attempt))
                            .foregroundStyle(attempt.outcome == .answered ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if attempt.manual {
                            Text("by hand")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("The log keeps the last \(PingProber.attemptLogLimit) probes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History\u{2026}") { isConfirmingClear = true }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .confirmationDialog("Forget every probe ever sent?",
                            isPresented: $isConfirmingClear) {
            Button("Clear History", role: .destructive) { prober.clearHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The counts and round trips go with it. The pacing rules start "
                 + "over, so stations that were backed off get asked again sooner.")
        }
    }

    // MARK: - Wording

    static func latency(_ rtt: TimeInterval) -> String {
        rtt < 1 ? String(format: "%.0f ms", rtt * 1000) : String(format: "%.1f s", rtt)
    }

    static func stamp(_ date: Date) -> String {
        let day = Calendar.current.isDateInToday(date)
            ? "" : date.formatted(.dateTime.month(.abbreviated).day()) + " "
        return day + TimeDisplay.timeString(date)
    }

    static func outcomeDescription(_ attempt: PingProber.Attempt) -> String {
        switch attempt.outcome {
        case .waiting:
            return "on the air, waiting"
        case .silent:
            return attempt.escalated
                ? "no answer to XID or DISC"
                : "no answer"
        case .answered:
            let rtt = attempt.rtt.map(latency) ?? "\u{2014}"
            let kind = attempt.answerKind ?? "answered"
            return attempt.escalated
                ? "\(kind) in \(rtt) \u{b7} ignored XID"
                : "\(kind) in \(rtt)"
        }
    }

    static func lastAnswerDescription(_ row: PingStatistics.StationRow) -> String {
        guard let answered = row.lastAnswered else {
            guard row.consecutiveSilences > 0 else { return "never answered" }
            return "never answered \u{b7} \(row.consecutiveSilences) in a row"
        }
        let kind = row.lastAnswerKind.map { " (\($0))" } ?? ""
        let silences = row.consecutiveSilences > 0
            ? " \u{b7} silent \(row.consecutiveSilences)\u{d7} since" : ""
        return stamp(answered) + kind + silences
    }

    static func stationHelp(_ row: PingStatistics.StationRow) -> String {
        var lines = ["\(row.call): \(row.probes) probes, \(row.answered) answered."]
        if let median = row.medianRTT {
            lines.append("Median round trip \(latency(median)).")
        }
        if let last = row.lastRTT {
            lines.append("Last answer took \(latency(last)).")
        }
        if row.consecutiveSilences > 0 {
            lines.append("\(row.consecutiveSilences) unanswered in a row, so its "
                         + "cooldown has doubled \(min(row.consecutiveSilences, 12)) times.")
        }
        return lines.joined(separator: "\n")
    }

    static func bucketHelp(_ bucket: PingStatistics.Bucket) -> String {
        let hour = TimeDisplay.timeString(bucket.start, seconds: false)
        guard bucket.probes > 0 else { return "\(hour): no probes" }
        return "\(hour): \(bucket.probes) probes, \(bucket.answered) answered"
    }
}
