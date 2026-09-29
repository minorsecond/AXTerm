import Foundation

/// Time labels for the session charts.
///
/// A packet session runs anywhere from a few seconds to an hour, and one
/// label style cannot serve that range. Wall-clock times like `4:34:41 AM`
/// are six or seven characters that say almost nothing under a
/// ninety-second chart — the interesting fact is *how far in*, not what the
/// kitchen clock said — and their width is what pushed the final tick off
/// the right-hand edge of the throughput panel.
///
/// So: elapsed time while a session is short enough for elapsed to mean
/// something, and the clock once it is long enough that an operator would
/// be correlating against a log instead.
nonisolated struct ChartTimeAxis: Equatable, Sendable {

    enum Style: Equatable, Sendable {
        /// `12s` — sub-minute sessions.
        case elapsedSeconds
        /// `3:05` — the common packet-session case.
        case elapsedMinutes
        /// `4:34 AM` — long enough that elapsed stops helping.
        case wallClock
    }

    /// Seconds from the first sample to the last.
    let span: TimeInterval
    let style: Style

    init(span: TimeInterval) {
        let span = max(0, span)
        self.span = span
        switch span {
        case ..<60: style = .elapsedSeconds
        case ..<3600: style = .elapsedMinutes
        default: style = .wallClock
        }
    }

    /// Four across a panel of this width. More is what crowded the labels
    /// into each other and off the edge.
    var desiredTickCount: Int { 4 }

    func label(for date: Date, start: Date) -> String {
        // Clocks are not monotonic. A sample stamped before the start —
        // after a time adjustment mid-session — must not render "-1:-5".
        let elapsed = max(0, date.timeIntervalSince(start))
        switch style {
        case .elapsedSeconds:
            return "\(Int(elapsed.rounded()))s"
        case .elapsedMinutes:
            let whole = Int(elapsed.rounded())
            return String(format: "%d:%02d", whole / 60, whole % 60)
        case .wallClock:
            return Self.clockFormatter.string(from: date)
        }
    }

    /// Short by construction: no seconds, no padded hour.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter
    }()
}
