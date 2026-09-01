import SwiftUI
import Charts
import Combine

/// Full-page live view of an exchange in progress.
///
/// The compact Activity strip answers "is it moving?". This answers the
/// questions you actually have while watching a slow transfer crawl: which
/// direction is losing frames, whether the gateway will cut the session
/// before the message lands, what the controller is doing about it, and how
/// much of the current message came from a previous attempt.
///
/// Everything here is measured, and every panel explains its derivation on
/// hover. Nothing is drawn that is not evidence.
struct WinlinkExchangeDashboardView: View {

    @ObservedObject var runner: WinlinkSessionRunner
    var viz: LinkSessionViz?
    var adaptive: AdaptiveParams?
    var gatewayName: String
    /// The gateway's previously observed session cap, from the session log.
    var observedCapSeconds: Double?

    @Environment(\.dismiss) private var dismiss
    /// Drives the elapsed clock and rate readouts without depending on a
    /// packet arriving to trigger a redraw — a stalled link is exactly when
    /// the numbers need to keep updating.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    transferPanel
                    adaptivePair {
                        panel("Link health", systemImage: "arrow.left.arrow.right") {
                            DirectionalHealthView(snapshot: viz?.snapshot)
                        }
                    } second: {
                        panel("Session budget", systemImage: "timer") {
                            SessionBudgetView(
                                startedAt: runner.progress?.startedAt ?? sessionStart,
                                observedCapSeconds: observedCapSeconds,
                                bytesRemaining: bytesRemaining,
                                bytesPerSecond: runner.progress?.bytesPerSecond(now: now),
                                now: now)
                        }
                    }
                    panel("Throughput", systemImage: "chart.line.uptrend.xyaxis",
                          help: throughputHelp, legend: ThroughputChartView.legend) {
                        ThroughputChartView(buckets: viz?.throughput.suffix(600) ?? [])
                            .frame(height: 150)
                    }
                    adaptivePair {
                        panel("Frames in flight", systemImage: "square.stack.3d.up",
                              legend: WindowSawtoothView.legend) {
                            WindowSawtoothView(samples: viz?.windowHistory ?? [])
                                .frame(height: 120)
                        }
                    } second: {
                        panel("Round-trip time", systemImage: "arrow.triangle.2.circlepath",
                              legend: RTTChartView.legend) {
                            RTTChartView(samples: viz?.rttHistory ?? [])
                                .frame(height: 120)
                        }
                    }
                    panel("Block arrivals", systemImage: "square.grid.3x3",
                          help: blocksHelp) {
                        BlockCadenceStrip(
                            deliveries: viz?.deliveries ?? [],
                            expectedTotalBytes: runner.progress?.bytesTotal,
                            receivedBytes: runner.progress?.bytesDone ?? 0)
                            .frame(height: 44)
                    }
                    panel("Adaptive parameters", systemImage: "dial.medium") {
                        AdaptiveSummaryView(params: adaptive)
                    }
                }
                .padding(16)
            }
        }
        #if os(macOS)
        // Window sizing. On iOS this is a sheet whose width the system owns,
        // and a hard 860pt minimum simply overflowed it — the panels were
        // clipped off both edges rather than being made to fit.
        .frame(minWidth: 860, idealWidth: 980, minHeight: 600, idealHeight: 720)
        #endif
        .background(Color(platform: .platformWindowBackground))
        .onReceive(tick) { now = $0 }
    }

    /// Two panels side by side where there is room, stacked where there is not.
    ///
    /// A Mac window is at least 860pt wide, so a pair always fits. A sheet is
    /// as wide as the system decides — on an iPad in a split view that can be
    /// under 600pt, and these panels carry charts and multi-line explanations
    /// that do not survive being halved.
    @ViewBuilder
    private func adaptivePair<First: View, Second: View>(
        @ViewBuilder first: () -> First,
        @ViewBuilder second: () -> Second
    ) -> some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 14) {
            first()
            second()
        }
        #else
        VStack(spacing: 14) {
            first()
            second()
        }
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(gatewayName)
                    .font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if runner.isRunning {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                    Text("Live")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .help("This exchange is running. The dashboard updates once a second.")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusLine: String {
        runner.statusText.isEmpty ? "Idle" : runner.statusText
    }

    // MARK: - Transfer panel

    @ViewBuilder
    private var transferPanel: some View {
        panel("Transfer", systemImage: "arrow.down.circle", help: transferHelp) {
            if let progress = runner.progress {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(progress.subject?.isEmpty == false
                             ? progress.subject!
                             : (progress.mid ?? kindLabel(progress.kind)))
                            .font(.title3.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(rateLine(progress))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ResumeAwareProgressBar(progress: progress)
                        .frame(height: 14)

                    HStack(spacing: 12) {
                        legend(.teal, "resumed \(bytes(progress.baselineBytes))",
                               show: progress.baselineBytes > 0)
                        legend(.accentColor, "this session \(bytes(progress.bytesThisSession))",
                               show: true)
                        legend(.secondary.opacity(0.3),
                               "remaining \(bytes(max(0, progress.bytesTotal - progress.bytesDone)))",
                               show: progress.bytesTotal > 0)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }
            } else {
                Text(runner.isRunning
                     ? "Handshaking — no body transfer in progress."
                     : "No transfer in progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func legend(_ color: Color, _ text: String, show: Bool) -> some View {
        if show {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Derived

    private var sessionStart: Date? {
        runner.isRunning ? (viz?.windowHistory.first?.date) : nil
    }

    private var bytesRemaining: Int {
        guard let progress = runner.progress, progress.bytesTotal > 0 else { return 0 }
        return max(0, progress.bytesTotal - progress.bytesDone)
    }

    private func rateLine(_ progress: WinlinkExchangeProgress) -> String {
        var parts = ["\(bytes(progress.bytesDone)) of \(bytes(progress.bytesTotal))"]
        if let rate = progress.bytesPerSecond(now: now), rate >= 1 {
            parts.append("\(Int(rate.rounded())) B/s")
        }
        if let seconds = progress.estimatedSecondsRemaining(now: now), seconds > 2 {
            parts.append("\(SessionBudgetView.clock(Double(seconds))) left")
        }
        return parts.joined(separator: " · ")
    }

    private func bytes(_ count: Int) -> String {
        ByteCount.string(Int64(count))
    }

    private func kindLabel(_ kind: WinlinkExchangeProgress.Kind) -> String {
        switch kind {
        case .connecting: return "Connecting"
        case .handshake: return "Signing in"
        case .sending: return "Sending"
        case .receiving: return "Receiving"
        }
    }

    // MARK: - Panel chrome

    @ViewBuilder
    private func panel<Content: View>(
        _ title: String,
        systemImage: String,
        help: String? = nil,
        legend: [ChartLegend.Item] = [],
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .modifier(OptionalHelp(help: help))
                Spacer(minLength: 12)
                // Beside the title rather than under the plot: it costs no
                // chart height, and it is the first thing read.
                if !legend.isEmpty {
                    ChartLegend(items: legend)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(platform: .platformCardBackground)))
    }

    // MARK: - Copy

    private var transferHelp: String {
        """
        The message currently on the air.

        Teal is what a previous, interrupted attempt already delivered — \
        those bytes are on disk and are not being re-downloaded. Only the \
        blue portion is crossing the air now, and the rate and time \
        remaining are computed from it alone.
        """
    }

    private var throughputHelp: String {
        """
        Bytes per second over time. Green is goodput — payload delivered in \
        order to the application. Orange behind it is every byte the channel \
        carried, including duplicate copies of frames we already had.

        The gap between the two is retransmission overhead. Averaging \
        adapts to the visible span, so a long session smooths rather than \
        turning into a picket fence.
        """
    }

    private var blocksHelp: String {
        """
        One cell per FBB block, in arrival order.

        Teal cells were carried over from an interrupted session. Green is a \
        block that arrived at the expected size; orange is a short block, \
        which usually means the gateway flushed early after a stall. Pale \
        cells are blocks still expected.
        """
    }
}

/// Applies `.help` only when there is something to say, so a panel without
/// copy does not get an empty tooltip.
private struct OptionalHelp: ViewModifier {
    let help: String?
    func body(content: Content) -> some View {
        if let help { content.help(help) } else { content }
    }
}

// MARK: - Progress bar

/// A progress bar that distinguishes bytes resumed from a prior session
/// from bytes moved now. The whole-message view is what the operator cares
/// about, but conflating the two makes a resumed transfer look far faster
/// than the link really is.
struct ResumeAwareProgressBar: View {

    let progress: WinlinkExchangeProgress

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let total = max(1, progress.bytesTotal)
            let resumed = width * CGFloat(min(progress.baselineBytes, total)) / CGFloat(total)
            let current = width * CGFloat(min(progress.bytesThisSession, total)) / CGFloat(total)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))
                HStack(spacing: 0) {
                    Rectangle().fill(Color.teal.opacity(0.75)).frame(width: resumed)
                    Rectangle().fill(Color.accentColor).frame(width: current)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Transfer progress")
        .accessibilityValue(progress.fraction.map { "\(Int($0 * 100)) percent" } ?? "unknown")
    }
}
