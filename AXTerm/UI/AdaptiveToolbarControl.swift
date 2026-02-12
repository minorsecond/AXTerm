import SwiftUI
import Charts
import AppKit

struct AdaptiveToolbarControl: View {
    @ObservedObject var store: AdaptiveStatusStore
    var onOpenAnalytics: (() -> Void)?
    @State private var isPopoverPresented = false

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text("Adaptive")
                    .font(.system(size: 11, weight: .semibold))

                if let effective = store.effectiveAdaptive {
                    Text("· K\(effective.k) P\(effective.p) N2 \(effective.n2)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                    if effective.destination != nil {
                        Text("· Session")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("· Waiting")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            AdaptivePopoverContent(store: store, onOpenAnalytics: onOpenAnalytics)
        }
        .help("Adaptive transmission status")
    }
}

private struct AdaptivePopoverContent: View {
    @ObservedObject var store: AdaptiveStatusStore
    var onOpenAnalytics: (() -> Void)?

    private let gridColumns: [GridItem] = [
        GridItem(.flexible(minimum: 160), spacing: 10),
        GridItem(.flexible(minimum: 160), spacing: 10)
    ]

    var body: some View {
        let adaptive = store.effectiveAdaptive
        VStack(alignment: .leading, spacing: 12) {
            header(adaptive: adaptive)

            LazyVGrid(columns: gridColumns, spacing: 10) {
                metricCard(label: "ETX", info: "Expected transmissions per successful frame. Lower is better.", value: adaptive.map { format($0.etx) } ?? "—", emphasized: true)
                metricCard(label: "Loss", info: "Recent frame loss estimate for this context.", value: adaptive.map { formatPercent($0.lossRate) } ?? "—")
                metricCard(label: "K", info: "Window size: outstanding frames allowed.", value: adaptive.map { "\($0.k)" } ?? "—")
                metricCard(label: "P", info: "Packet size in bytes.", value: adaptive.map { "\($0.p)" } ?? "—")
                metricCard(label: "N2", info: "Maximum retries before fail.", value: adaptive.map { "\($0.n2)" } ?? "—")
                metricCard(label: "RTO", info: "Current retransmission timeout.", value: adaptive.map { formatSeconds($0.currentRto) } ?? "—")
            }

            etxChart

            HStack(spacing: 10) {
                Button("Copy Metrics") {
                    copyMetrics()
                }
                .buttonStyle(.link)

                if let onOpenAnalytics {
                    Button("Open Analytics…") {
                        onOpenAnalytics()
                    }
                    .buttonStyle(.link)
                }
                Spacer()
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .frame(width: 440)
    }

    @ViewBuilder
    private func header(adaptive: AdaptiveParams?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Adaptive")
                    .font(.system(size: 15, weight: .semibold))
                if let updated = adaptive?.updatedAt {
                    Text("Updated \(relativeDate(updated))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(contextChipText(adaptive: adaptive))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.1), in: Capsule())
        }
    }

    @ViewBuilder
    private var etxChart: some View {
        let points = store.effectiveETXHistory.sorted { $0.timestamp < $1.timestamp }
        if chartHasEnoughData(points) {
            Chart(points) { sample in
                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("ETX", sample.etx)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.accentColor)
            }
            .frame(height: 140)
            .chartYAxisLabel("ETX", position: .leading)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4))
            }
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .frame(height: 110)
                .overlay {
                    Text("Collecting metrics…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
        }
    }

    @ViewBuilder
    private func metricCard(label: String, info: String, value: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help(info)
                Spacer()
            }
            Text(value)
                .font(.system(size: emphasized ? 16 : 14, weight: emphasized ? .semibold : .medium))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
    }

    private func contextChipText(adaptive: AdaptiveParams?) -> String {
        // Session information moved to consolidated header - show only global/network status
        if let destination = adaptive?.destination {
            return "\(destination)"  // Show just destination without "Session:" prefix
        }
        return "Global Network"
    }

    private func chartHasEnoughData(_ points: [AdaptiveETXSample]) -> Bool {
        guard points.count >= 3, let first = points.first, let last = points.last else { return false }
        return last.timestamp.timeIntervalSince(first.timestamp) >= 30
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    private func formatSeconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1fs", value)
    }

    private func copyMetrics() {
        guard let adaptive = store.effectiveAdaptive else { return }
        let scope: String
        if let destination = adaptive.destination {
            scope = "Session \(destination)"
        } else {
            scope = "Global"
        }
        let summary = "\(scope) Adaptive K\(adaptive.k) P\(adaptive.p) N2 \(adaptive.n2) ETX \(format(adaptive.etx)) Loss \(formatPercent(adaptive.lossRate)) RTO \(formatSeconds(adaptive.currentRto))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }
}
