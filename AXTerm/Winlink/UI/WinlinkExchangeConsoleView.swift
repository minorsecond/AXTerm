import SwiftUI

/// Popdown exchange console: the live wire transcript of the B2F
/// conversation (TX/RX lines and protocol events), monospaced, with
/// auto-scroll. Persists after the exchange ends so a result can be
/// reviewed later; cleared when the next exchange starts.
struct WinlinkExchangeConsoleView: View {

    @ObservedObject var runner: WinlinkSessionRunner
    /// Live link aggregates for the gateway this exchange talks to.
    var viz: LinkSessionViz?
    var gatewayName: String = "Gateway"
    /// Adaptive state for this route, shown in the full dashboard.
    var adaptive: AdaptiveParams?
    /// Longest session this gateway has previously allowed, measured from
    /// the session log — the dashboard projects against it.
    var observedCapSeconds: Double?

    private enum Mode: String, CaseIterable {
        case transcript = "Transcript"
        case activity = "Activity"
    }
    @State private var mode: Mode = .transcript
    @State private var showReplay = false
    @State private var showDashboard = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            // The sheet is the whole screen here, so it owes the operator a
            // plain-language answer before the protocol lines start.
            WinlinkExchangeStatusHeader(runner: runner, gatewayName: gatewayName)
            Divider()
            #endif
            consoleHeader
            Divider()
            if mode == .activity {
                activityPane
            } else if runner.transcript.isEmpty {
                Text("No exchange yet — the conversation with the gateway will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: rowSpacing) {
                            ForEach(runner.transcript) { entry in
                                row(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    // Scoped to the transcript pane only — a container-level
                    // help would shadow the per-chart tooltips in Activity.
                    .help("The raw B2F conversation with the gateway: sent lines (→), received lines (←), and session events. Binary message bodies are summarized by size.")
                    .onChange(of: runner.transcript.count) { _ in
                        if let last = runner.transcript.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if let last = runner.transcript.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        #if os(macOS)
        // Popdown under a window that already carries the progress card.
        .frame(height: 190)
        #else
        // Sheet-sized: a fixed 190pt box left most of an iPad screen empty
        // and pinned the transcript to the bottom edge.
        .frame(maxHeight: .infinity)
        #endif
        .frame(maxWidth: .infinity)
        .background(Color(platform: .platformTextBackground))
        .sheet(isPresented: $showReplay) {
            WinlinkExchangeReplayView(transcript: runner.transcript, gatewayName: gatewayName)
        }
        .sheet(isPresented: $showDashboard) {
            WinlinkExchangeDashboardView(
                runner: runner,
                viz: viz,
                adaptive: adaptive,
                gatewayName: gatewayName,
                observedCapSeconds: observedCapSeconds)
        }
    }

    /// Pointer targets can be glyph-sized; fingers cannot.
    private var touchTarget: CGFloat {
        #if os(iOS)
        return 34
        #else
        return 20
        #endif
    }

    /// Transcript lines sit tighter on a Mac, where the console is a strip.
    private var rowSpacing: CGFloat {
        #if os(iOS)
        return 3
        #else
        return 1
        #endif
    }

    private var consoleHeader: some View {
        HStack(spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .help("Transcript shows the raw B2F conversation. Activity shows the link live: throughput, block arrivals, and the AX.25 sliding window.")
            Spacer()
            if let viz, viz.totalRawBytes > 0 {
                Text(overheadSummary(viz))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Receive-side statistics for this link: bytes delivered in order, and the share of channel bytes spent on retransmitted copies.")
            }
            Button {
                showDashboard = true
            } label: {
                Image(systemName: "chart.bar.doc.horizontal")
                    .frame(width: touchTarget, height: touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open the full performance dashboard: both directions of link health, the gateway's observed session cap and what will fit inside it, throughput, frames in flight, round-trip time, and what the adaptive controller is doing.")

            Button {
                showReplay = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .frame(width: touchTarget, height: touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(runner.transcript.isEmpty)
            .help("Replay this session as a sequence diagram — every line of the conversation drawn as arrows between your station and the gateway, with binary transfers collapsed.")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var activityPane: some View {
        HStack(spacing: 10) {
            if let viz {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Blocks")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    BlockCadenceStrip(
                        deliveries: viz.deliveries,
                        expectedTotalBytes: runner.progress?.bytesTotal,
                        receivedBytes: runner.progress?.bytesDone ?? 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Throughput")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ThroughputChartView(buckets: viz.throughput.suffix(180))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(spacing: 4) {
                    Text("Window")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    WindowRingView(snapshot: viz.snapshot)
                        .frame(width: 110)
                }
            } else {
                Text("No link activity yet — start an exchange to see the transfer live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
    }

    private func overheadSummary(_ viz: LinkSessionViz) -> String {
        let delivered = ByteCountFormatter.string(fromByteCount: Int64(viz.totalDeliveredBytes), countStyle: .binary)
        let overhead = Int((viz.receiveOverheadFraction * 100).rounded())
        return "\(delivered) · \(overhead)% retx · \(viz.rejCount) REJ"
    }

    private func row(_ entry: WinlinkTranscriptEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(TimeDisplay.timeString(entry.timestamp))
                .font(.caption2.monospaced())
                .foregroundStyle(.quaternary)

            Text(prefix(for: entry.direction))
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(color(for: entry.direction))
                .frame(width: 14, alignment: .center)

            Text(entry.text)
                .font(.caption.monospaced())
                .foregroundStyle(entry.direction == .event ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func prefix(for direction: WinlinkTranscriptEntry.Direction) -> String {
        switch direction {
        case .sent: return "→"
        case .received: return "←"
        case .event: return "·"
        }
    }

    private func color(for direction: WinlinkTranscriptEntry.Direction) -> Color {
        switch direction {
        case .sent: return .blue
        case .received: return .green
        case .event: return .secondary
        }
    }
}
