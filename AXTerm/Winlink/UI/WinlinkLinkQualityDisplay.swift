import SwiftUI

/// Renders `WinlinkLinkQuality` for the Stations table's Link column.
///
/// The column answers one question — "what actually happens when I call
/// this gateway from here?" — and the tooltip must show its work: which
/// sessions it counted, how the rate was derived, and how much the
/// measurement's age and origin should be trusted. Per CLAUDE.md a metric
/// that cannot explain itself does not belong in the UI.
extension WinlinkLinkQuality {

    /// Everything the Link cell needs. Kept as plain data so the wording
    /// is testable without instantiating a view.
    nonisolated struct Presentation: Equatable, Sendable {
        var text: String
        var systemImage: String
        /// Nil renders in the secondary label colour (no claim being made).
        var tint: LinkTint
        var tooltip: String
    }

    nonisolated enum LinkTint: Equatable, Sendable {
        case good
        case marginal
        case bad
        case neutral
    }

    /// No sessions at all — the CMS lists the gateway, we've never called it.
    static func unobservedPresentation(callsign: String, frequencyHz: Int) -> Presentation {
        Presentation(
            text: "—",
            systemImage: "minus",
            tint: .neutral,
            tooltip: """
                No exchange attempted with \(callsign) on \(frequencyText(frequencyHz)) yet.

                This column reports what AXTerm actually measured, not what \
                the Winlink CMS advertises. Distance and baud come from the \
                directory; whether you can work the gateway from here is \
                something only an attempt can establish.
                """)
    }

    func presentation(now: Date = Date()) -> Presentation {
        guard attempts > 0, let lastAttemptAt else {
            return Self.unobservedPresentation(callsign: callsign, frequencyHz: frequencyHz ?? 0)
        }
        let age = Self.ageText(from: lastAttemptAt, to: now)

        // Samples from a known-different place are reference material.
        // Showing them at the same weight as local ones would invite
        // reading them as a prediction, which is exactly the mistake this
        // column exists to prevent.
        if case .elsewhere = placement {
            let value = effectiveBytesPerSecond.map { "\(Int($0.rounded())) B/s" } ?? "seen"
            return Presentation(
                text: "\(value) elsewhere",
                systemImage: "location.slash",
                tint: .neutral,
                tooltip: tooltip(age: age, now: now))
        }

        // `.unknown` is not `.elsewhere`: these samples may well have been
        // taken right here, we simply cannot prove it. Report what was
        // measured, but withhold the colour-coded verdict.
        let unverifiedPlace = placement == .unknown

        if lastAttemptWasSilent {
            return Presentation(
                text: "No answer · \(age)",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                tint: unverifiedPlace ? .neutral : .bad,
                tooltip: tooltip(age: age, now: now))
        }

        guard let rate = effectiveBytesPerSecond else {
            return Presentation(
                text: "Answered · \(age)",
                systemImage: "checkmark.circle",
                tint: unverifiedPlace ? .neutral : .marginal,
                tooltip: tooltip(age: age, now: now))
        }

        // 1200-baud AX.25 tops out near 150 B/s of payload; anything above
        // ~40 B/s is a healthy packet path, and under ~15 B/s means most
        // of the airtime is going to retries.
        let tint: LinkTint = rate >= 40 ? .good : (rate >= 15 ? .marginal : .bad)
        return Presentation(
            text: "\(Int(rate.rounded())) B/s · \(age)",
            systemImage: "antenna.radiowaves.left.and.right",
            tint: unverifiedPlace ? .neutral : tint,
            tooltip: tooltip(age: age, now: now))
    }

    // MARK: - Tooltip

    private func tooltip(age: String, now: Date) -> String {
        var lines = ["\(callsign)\(frequencyHz.map { " · " + Self.frequencyText($0) } ?? "")"]
        lines.append("")

        lines.append("Answered \(answered) of \(attempts) "
                     + (attempts == 1 ? "attempt" : "attempts")
                     + (completed > 0 ? "; \(completed) completed the full exchange." : "."))

        if let rate = effectiveBytesPerSecond {
            let bytes = ByteCount.string(Int64(bytesSent + bytesReceived))
            lines.append("Goodput \(Int(rate.rounded())) B/s — \(bytes) of mail over "
                         + "\(Self.durationText(measuredSeconds)) connected. "
                         + "That is payload divided by wall-clock link time, so "
                         + "retries, ACK waits, and a busy channel are all counted "
                         + "against it.")
        } else if answered > 0 {
            lines.append("Too little traffic so far to state a rate — a few seconds "
                         + "of link time is not a measurement.")
        }

        if longestSessionSeconds > 0 {
            lines.append("Longest session \(Self.durationText(longestSessionSeconds)).")
        }

        if let lastResult, let lastAttemptAt {
            let when = age == "just now" ? "just now" : "\(age) ago"
            lines.append("Last attempt \(when) "
                         + "(\(lastAttemptAt.formatted(date: .abbreviated, time: .shortened))): \(lastResult).")
        }

        lines.append("")
        lines.append(placementExplanation)
        if frequencyHz == nil {
            // Shown against every row for this callsign, because nothing
            // in the record says which of its frequencies was used.
            lines.append("")
            lines.append("These sessions predate per-frequency logging, so they may "
                         + "describe any of this callsign's frequencies — and a 9600-baud "
                         + "link behaves nothing like a 1200-baud one. Future sessions "
                         + "are recorded per frequency.")
        }
        lines.append("")
        lines.append("From AXTerm's own session log, not the CMS directory.")
        return lines.joined(separator: "\n")
    }

    /// The geographic caveat, stated at the strength the evidence supports.
    var placementExplanation: String {
        switch placement {
        case .here:
            return "Measured from where you are now, so it describes this path."
        case .nearby(let km):
            return String(
                format: "Measured %.1f km from here. Close enough that the path is "
                    + "probably similar, but a ridge or a different antenna site "
                    + "between the two spots can change it completely.", km)
        case .elsewhere(let grid, let km):
            let where_ = grid.isEmpty ? "" : " (\(grid))"
            return String(
                format: "Measured %.0f km away%@ — a different link. Whether a "
                    + "gateway is reachable depends on both endpoints, so this is "
                    + "shown for reference and predicts nothing about what you "
                    + "will get from here.", km, where_)
        case .unknown:
            return "These sessions carry no position, so AXTerm cannot tell whether "
                + "they were taken from here. Sessions recorded from now on will say."
        }
    }

    // MARK: - Formatting

    static func frequencyText(_ hz: Int) -> String {
        guard hz > 0 else { return "—" }
        return String(format: "%.3f MHz", Double(hz) / 1_000_000)
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 {
            let minutes = total / 60, rest = total % 60
            return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
        }
        return String(format: "%.1f h", seconds / 3600)
    }

    static func ageText(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<90: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(30 * 86_400): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (30 * 86_400)))mo"
        }
    }
}

extension WinlinkLinkQuality.LinkTint {
    var color: Color {
        switch self {
        case .good: return .green
        case .marginal: return .orange
        case .bad: return .red
        case .neutral: return .secondary
        }
    }
}
