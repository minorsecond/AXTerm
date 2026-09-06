import SwiftUI
import Charts

// MARK: - Directional link health

/// The two directions of an AX.25 link, side by side.
///
/// A single "link quality" number hides the case that matters most on
/// packet: an asymmetric path. During a download we transmit almost
/// nothing, so a forward-only metric reports a perfect link while the
/// gateway's frames are being shredded on the way in. Showing df and dr
/// separately — with the frame counts each is derived from — makes the
/// asymmetry the first thing you see rather than something you infer.
struct DirectionalHealthView: View {

    let snapshot: LinkWindowSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot, snapshot.df != nil || snapshot.dr != nil {
                HStack(alignment: .top, spacing: 14) {
                    direction(
                        title: "Outbound",
                        subtitle: "our frames → gateway",
                        probability: snapshot.df,
                        good: snapshot.framesSent,
                        bad: snapshot.retransmissions,
                        badLabel: snapshot.retransmissions == 1 ? "retransmit" : "retransmits",
                        symbol: "arrow.up.right",
                        help: """
                            Forward delivery probability (df) = I-frames that landed first try.

                            \(snapshot.framesSent) sent, \(snapshot.retransmissions) retransmitted → \
                            df = 1 − \(snapshot.retransmissions)/\(snapshot.framesSent + snapshot.retransmissions) \
                            = \(Self.percent(snapshot.df)).

                            A retransmit means either our frame or the gateway's \
                            acknowledgement was lost, so this figure blames the \
                            round trip, not just the outbound leg.
                            """)

                    Divider().frame(height: 62)

                    direction(
                        title: "Inbound",
                        subtitle: "gateway → our frames",
                        probability: snapshot.dr,
                        good: snapshot.framesReceived,
                        bad: snapshot.rejSent,
                        badLabel: snapshot.rejSent == 1 ? "gap (REJ)" : "gaps (REJ)",
                        symbol: "arrow.down.left",
                        help: """
                            Reverse delivery probability (dr) = the gateway's I-frames \
                            that reached us without a gap.

                            \(snapshot.framesReceived) received, \(snapshot.rejSent) REJs sent → \
                            dr = 1 − \(snapshot.rejSent)/\(snapshot.framesReceived + snapshot.rejSent) \
                            = \(Self.percent(snapshot.dr)).

                            Every REJ is us telling the gateway a frame never \
                            arrived, so this is direct evidence of loss on the \
                            way in — the direction a download depends on.
                            """)
                }

                Divider()
                etxRow(snapshot)
            } else {
                Text("No frames yet — both directions need traffic before they can be measured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func direction(
        title: String,
        subtitle: String,
        probability: Double?,
        good: Int,
        bad: Int,
        badLabel: String,
        symbol: String,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(Self.percent(probability))
                .font(.system(size: 26, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Self.tint(probability))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("\(good) ok · \(bad) \(badLabel)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }

    @ViewBuilder
    private func etxRow(_ snapshot: LinkWindowSnapshot) -> some View {
        HStack(spacing: 6) {
            Text("ETX")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(snapshot.etx.map { String(format: "%.2f", $0) } ?? "—")
                .font(.body.monospacedDigit().weight(.medium))
            Text(Self.etxReading(snapshot))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .help("""
            Expected transmissions to get one frame across and acknowledged:
            ETX = 1 / (df × dr), clamped to 1–20.

            Both directions are separate terms. Using df for both — the \
            symmetric shortcut — reports a clean link whenever we happen to \
            be the quiet end, which during a download is always.
            """)
    }

    /// Says what the number means for this transfer, not what ETX is.
    private static func etxReading(_ snapshot: LinkWindowSnapshot) -> String {
        guard let etx = snapshot.etx else { return "" }
        let forward = snapshot.df ?? 1
        let reverse = snapshot.dr ?? 1
        if etx < 1.1 { return "— both directions clean" }
        let asymmetric = abs(forward - reverse) > 0.1
        let worse = forward < reverse ? "outbound" : "inbound"
        if asymmetric {
            return String(format: "— %@ is the weak direction; %.0f%% of capacity is going to repeats",
                          worse, (1 - 1 / etx) * 100)
        }
        return String(format: "— both directions lossy; %.0f%% of capacity is going to repeats",
                      (1 - 1 / etx) * 100)
    }

    private static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    private static func tint(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value >= 0.95 { return .green }
        if value >= 0.85 { return .orange }
        return .red
    }
}

// MARK: - Session budget

/// Elapsed session time against the cap this gateway has been observed to
/// enforce, plus what that means for the transfer in progress.
///
/// Some RMS gateways disconnect on a timer regardless of how well the link
/// is working — W0ARP-10 cuts at about 17½ minutes. When that is true, the
/// question is not "will this finish?" but "how much will land before the
/// cut, and how much resumes next time?". This panel answers that instead
/// of counting down to an ETA the session will never reach.
/// The arithmetic behind `SessionBudgetView`, separated so the projection
/// can be tested without a view hierarchy.
nonisolated struct SessionBudget: Equatable, Sendable {

    let startedAt: Date?
    /// Longest session this gateway has previously allowed, if any. Values
    /// at or under a minute are treated as no evidence of a cap — a short
    /// session usually means the link failed, not that a timer fired.
    let observedCapSeconds: Double?
    /// Bytes still to transfer for the current message.
    let bytesRemaining: Int
    /// Current goodput, bytes/second.
    let bytesPerSecond: Double?
    let now: Date

    var elapsed: Double {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    var hasCap: Bool { (observedCapSeconds ?? 0) > 60 }

    /// Seconds left before the observed cap, if one is known.
    var secondsToCap: Double? {
        guard hasCap, let observedCapSeconds else { return nil }
        return max(0, observedCapSeconds - elapsed)
    }

    /// Bytes expected to land before the cap cuts in.
    var bytesBeforeCap: Int? {
        guard let secondsToCap, let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return Int(secondsToCap * bytesPerSecond)
    }

    /// Bytes that will not fit inside this session and will be resumed on
    /// the next one. Zero when the transfer fits.
    var bytesCarriedToNextSession: Int {
        guard bytesRemaining > 0, let bytesBeforeCap else { return 0 }
        return max(0, bytesRemaining - bytesBeforeCap)
    }

    /// Whether the current message can finish inside this session.
    var finishesThisSession: Bool? {
        guard bytesRemaining > 0 else { return true }
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        guard let secondsToCap else { return nil }
        return Double(bytesRemaining) / bytesPerSecond <= secondsToCap
    }
}

struct SessionBudgetView: View {

    let startedAt: Date?
    /// Longest session this gateway has previously allowed, if any.
    let observedCapSeconds: Double?
    /// Bytes still to transfer for the current message.
    let bytesRemaining: Int
    /// Current goodput, bytes/second.
    let bytesPerSecond: Double?
    let now: Date

    private var budget: SessionBudget {
        SessionBudget(
            startedAt: startedAt,
            observedCapSeconds: observedCapSeconds,
            bytesRemaining: bytesRemaining,
            bytesPerSecond: bytesPerSecond,
            now: now)
    }

    private var elapsed: Double { budget.elapsed }
    private var secondsToCap: Double? { budget.secondsToCap }
    private var bytesBeforeCap: Int? { budget.bytesBeforeCap }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.clock(elapsed))
                    .font(.system(size: 24, weight: .medium, design: .rounded).monospacedDigit())
                if let observedCapSeconds, observedCapSeconds > 60 {
                    Text("of ~\(Self.clock(observedCapSeconds)) observed cap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let observedCapSeconds, observedCapSeconds > 60 {
                ProgressView(value: min(1, elapsed / observedCapSeconds))
                    .tint(elapsed / observedCapSeconds > 0.85 ? .orange : .accentColor)
            }

            Text(projection)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("""
            How long this session has been up, against the longest session \
            this gateway has previously allowed.

            Some gateways disconnect on a timer no matter how healthy the \
            link is. When that happens mid-body, AXTerm saves the bytes \
            received so far and the next exchange asks the gateway to resume \
            from that offset (FS !offset), so nothing already transferred is \
            downloaded twice.

            The cap shown is measured from your own past sessions with this \
            gateway, not advertised by it.
            """)
    }

    private var projection: String {
        guard bytesRemaining > 0 else {
            return "Nothing left to transfer for this message."
        }
        guard let bytesPerSecond, bytesPerSecond > 0 else {
            return "Measuring throughput…"
        }
        let secondsNeeded = Double(bytesRemaining) / bytesPerSecond
        let remainingText = ByteCount.string(Int64(bytesRemaining))

        guard let secondsToCap, let bytesBeforeCap else {
            return "\(remainingText) to go — about \(Self.clock(secondsNeeded)) at "
                + "\(Int(bytesPerSecond.rounded())) B/s. No session cap observed for this gateway yet."
        }

        if secondsNeeded <= secondsToCap {
            return "\(remainingText) to go — about \(Self.clock(secondsNeeded)) at "
                + "\(Int(bytesPerSecond.rounded())) B/s, finishing with "
                + "\(Self.clock(secondsToCap - secondsNeeded)) of session budget to spare."
        }

        let carried = budget.bytesCarriedToNextSession
        return "\(remainingText) to go, but only about "
            + "\(ByteCount.string(Int64(bytesBeforeCap))) "
            + "fits before the cap. The remaining "
            + "\(ByteCount.string(Int64(carried))) "
            + "will be saved and resumed on the next exchange — not re-downloaded."
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Adaptive parameters

/// What the link controller has settled on, and why.
struct AdaptiveSummaryView: View {

    let params: AdaptiveParams?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let params {
                HStack(spacing: 14) {
                    stat("K", "\(params.k)", "Window — frames allowed in flight at once.")
                    stat("PACLEN", "\(params.p)", "Bytes of payload per I-frame. Smaller frames survive a lossy channel better but carry more overhead.")
                    stat("N2", "\(params.n2)", "Retries before the link is declared dead.")
                    if let rto = params.currentRto {
                        stat("RTO", String(format: "%.1fs", rto),
                             "Retransmission timeout, derived from measured round-trip time.")
                    }
                }
                Text(params.learningNarrative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !params.activitySummary.isEmpty {
                    Text(params.activitySummary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Adaptive transmission is off, or no samples have been taken on this route yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stat(_ label: String, _ value: String, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.body.monospacedDigit().weight(.medium))
        }
        .help(help)
    }
}
