import SwiftUI

/// Compact live progress card for a running mail exchange: phase,
/// per-message determinate bar, byte counts, rate, and time remaining.
struct WinlinkExchangeProgressView: View {

    @ObservedObject var runner: WinlinkSessionRunner

    var body: some View {
        if let progress = runner.progress {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                card(progress, now: timeline.date)
            }
            .transition(.opacity)
        } else if runner.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(runner.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func card(_ progress: WinlinkExchangeProgress, now: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: progress.kind))
                .foregroundStyle(.tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: progress))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 190)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 190)
                }

                Text(detailLine(for: progress, now: now))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help(WinlinkCopy.connectExchangeTooltip)
        .accessibilityElement(children: .combine)
    }

    private func icon(for kind: WinlinkExchangeProgress.Kind) -> String {
        switch kind {
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .handshake: return "hand.wave"
        case .sending: return "arrow.up.circle"
        case .receiving: return "arrow.down.circle"
        }
    }

    private func title(for progress: WinlinkExchangeProgress) -> String {
        switch progress.kind {
        case .connecting: return "Connecting…"
        case .handshake: return "Handshaking…"
        case .sending:
            if let subject = progress.subject, !subject.isEmpty {
                return "Sending “\(subject)”"
            }
            return "Sending \(progress.mid ?? "message")"
        case .receiving:
            return "Receiving \(progress.mid ?? "message")"
        }
    }

    private func detailLine(for progress: WinlinkExchangeProgress, now: Date) -> String {
        guard progress.bytesTotal > 0 else { return runner.statusText }

        var parts = [String]()
        parts.append("\(byteText(progress.bytesDone)) of \(byteText(progress.bytesTotal))")
        if let rate = progress.bytesPerSecond(now: now) {
            parts.append("\(byteText(Int(rate)))/s")
        }
        if let seconds = progress.estimatedSecondsRemaining(now: now), seconds > 2 {
            parts.append("about \(timeText(seconds)) left")
        }
        return parts.joined(separator: " · ")
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func timeText(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: return "\(seconds) s"
        case ..<3600: return "\((seconds + 30) / 60) min"
        default: return String(format: "%.1f h", Double(seconds) / 3600)
        }
    }
}
