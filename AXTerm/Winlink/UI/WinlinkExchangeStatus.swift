import SwiftUI

/// What the exchange console says the session is doing, derived once so the
/// wording can be tested without a view.
///
/// The console used to show nothing but a transcript. On a Mac that is fine —
/// the popdown sits under a window that already carries the progress card. On
/// a handheld the sheet *is* the whole screen, so an operator watching a
/// session had a wall of protocol lines and no plain-language answer to "is it
/// working?". This type is that answer.
nonisolated struct WinlinkExchangeStatus: Equatable {

    /// Drives the icon and its colour. Kept separate from the text so a
    /// glance is enough when the wording is too long to read.
    enum Kind: Equatable {
        case idle
        case working
        case succeeded
        case failed
    }

    var kind: Kind
    /// Short phase label — "Connecting", "Receiving", "Complete".
    var title: String
    /// One line of detail under the title, or nil when there is nothing to add.
    var detail: String?
    /// 0…1 when the transfer size is known, nil when indeterminate.
    var fraction: Double?
    /// Right-aligned byte counter, e.g. "1.2 KB of 4.6 KB".
    var byteSummary: String?
    /// Rate and estimate, e.g. "112 B/s · about 30s left".
    var rateSummary: String?

    var isWorking: Bool { kind == .working }

    var symbol: String {
        switch kind {
        case .idle: return "antenna.radiowaves.left.and.right.slash"
        case .working: return "antenna.radiowaves.left.and.right"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Derivation

    /// Builds the status from the runner's published state.
    ///
    /// `now` is injected so the rate and estimate are testable.
    static func make(phase: WinlinkSessionRunner.Phase,
                     statusText: String,
                     progress: WinlinkExchangeProgress?,
                     summary: WinlinkExchangeSummary?,
                     now: Date = Date()) -> WinlinkExchangeStatus {

        switch phase {
        case .failed(let reason):
            return WinlinkExchangeStatus(
                kind: .failed, title: "Exchange failed", detail: reason)

        case .done:
            // A finished session reports what moved. "Complete" alone invites
            // the operator to go hunting in the transcript for the counts.
            return WinlinkExchangeStatus(
                kind: .succeeded,
                title: "Exchange complete",
                detail: summary.map(completionDetail) ?? nil)

        case .idle:
            return WinlinkExchangeStatus(
                kind: .idle,
                title: "Not connected",
                detail: "Start an exchange to open a session with the gateway.")

        case .preparing, .connecting, .exchanging:
            let trimmed = statusText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let progress else {
                return WinlinkExchangeStatus(
                    kind: .working,
                    title: workingTitle(phase),
                    detail: trimmed.isEmpty ? nil : trimmed)
            }
            return WinlinkExchangeStatus(
                kind: .working,
                title: title(for: progress.kind),
                // The message subject beats a generic phase line while a body
                // is actually moving; fall back to the runner's own words.
                detail: progress.subject ?? (trimmed.isEmpty ? nil : trimmed),
                fraction: progress.fraction,
                byteSummary: byteSummary(progress),
                rateSummary: rateSummary(progress, now: now))
        }
    }

    private static func workingTitle(_ phase: WinlinkSessionRunner.Phase) -> String {
        switch phase {
        case .preparing: return "Preparing"
        case .connecting: return "Connecting"
        default: return "Exchanging"
        }
    }

    private static func title(for kind: WinlinkExchangeProgress.Kind) -> String {
        switch kind {
        case .connecting: return "Connecting"
        case .handshake: return "Handshaking"
        case .sending: return "Sending"
        case .receiving: return "Receiving"
        }
    }

    private static func completionDetail(_ summary: WinlinkExchangeSummary) -> String? {
        let sent = summary.sentMIDs.count
        let received = summary.receivedMIDs.count
        if sent == 0 && received == 0 {
            // The commonest real outcome, and the one most likely to be read
            // as a failure if it is not named plainly.
            return "Nothing queued either way — the mailbox is up to date."
        }
        var parts: [String] = []
        if sent > 0 { parts.append("Sent \(sent) message\(sent == 1 ? "" : "s")") }
        if received > 0 { parts.append("Received \(received) message\(received == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private static func byteSummary(_ progress: WinlinkExchangeProgress) -> String? {
        guard progress.bytesTotal > 0 else {
            guard progress.bytesDone > 0 else { return nil }
            return compact(progress.bytesDone)
        }
        return "\(compact(progress.bytesDone)) of \(compact(progress.bytesTotal))"
    }

    private static func rateSummary(_ progress: WinlinkExchangeProgress, now: Date) -> String? {
        var parts: [String] = []
        if let rate = progress.bytesPerSecond(now: now) {
            parts.append("\(compact(Int(rate.rounded())))/s")
        }
        if let remaining = progress.estimatedSecondsRemaining(now: now) {
            parts.append("about \(duration(remaining)) left")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Sizes on a packet link are small enough that the binary formatter's
    /// "1 KB" for 1,024 bytes hides real differences. Bytes stay bytes until
    /// they stop being readable.
    static func compact(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 10 { return String(format: "%.1f KB", kb) }
        if kb < 1024 { return "\(Int(kb.rounded())) KB" }
        return String(format: "%.1f MB", kb / 1024)
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes < 60 { return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}


/// The banner at the top of the exchange console.
///
/// Sized for a thumb: on a handheld this is the first thing an operator looks
/// at when a session is slow, and it has to answer "what is it doing, how far
/// along, and how long" without them parsing B2F.
struct WinlinkExchangeStatusHeader: View {

    @ObservedObject var runner: WinlinkSessionRunner
    var gatewayName: String

    var body: some View {
        // Ticks once a second so the rate and estimate stay honest while a
        // slow transfer runs; idle sessions publish nothing and stay still.
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(WinlinkExchangeStatus.make(
                phase: runner.phase,
                statusText: runner.statusText,
                progress: runner.progress,
                summary: runner.lastSummary,
                now: timeline.date))
        }
    }

    @ViewBuilder
    private func content(_ status: WinlinkExchangeStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                icon(status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title)
                        .font(.headline)
                    if let detail = status.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if status.isWorking {
                    ProgressView().controlSize(.small)
                }
            }

            if status.fraction != nil || status.byteSummary != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = status.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                    } else if status.isWorking {
                        // Size unknown — an indeterminate bar still shows the
                        // link is alive, which a static label does not.
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        if let bytes = status.byteSummary {
                            Text(bytes)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let rate = status.rateSummary {
                            Text(rate)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .explain(explanation(status), showsIndicator: false)
    }

    private func icon(_ status: WinlinkExchangeStatus) -> some View {
        Image(systemName: status.symbol)
            .font(.title3)
            .foregroundStyle(tint(status))
            .frame(width: 26, height: 26)
            .symbolRenderingMode(.hierarchical)
    }

    private func tint(_ status: WinlinkExchangeStatus) -> Color {
        switch status.kind {
        case .idle: return .secondary
        case .working: return .accentColor
        case .succeeded: return .green
        case .failed: return .orange
        }
    }

    /// Says why the numbers read as they do, not merely what they are.
    private func explanation(_ status: WinlinkExchangeStatus) -> String {
        switch status.kind {
        case .idle:
            return "No session is open with \(gatewayName). Nothing is being transmitted."
        case .failed:
            return "The session with \(gatewayName) ended early. The transcript below holds the gateway's own words for why — the last few lines are usually the reason."
        case .succeeded:
            return "The session with \(gatewayName) finished cleanly and the link was closed. Counts are messages that changed hands, not bytes."
        case .working:
            var lines = ["A session with \(gatewayName) is open and \(status.title.lowercased())."]
            if status.fraction != nil {
                lines.append("The bar measures compressed bytes — what actually crosses the air — so it advances slower than the message's own size would suggest.")
            } else {
                lines.append("The size is not known yet, so the bar shows only that the link is live.")
            }
            if status.rateSummary != nil {
                lines.append("The rate is measured over this message alone; an estimate on a packet link moves around as the channel clears and fills.")
            }
            return lines.joined(separator: " ")
        }
    }
}
