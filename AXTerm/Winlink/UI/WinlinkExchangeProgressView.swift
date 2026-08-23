import SwiftUI

/// Live progress for a running mail exchange.
///
/// Two presentations, both quiet and toolbar-sized:
/// - indeterminate phases (connecting, signing in): a small spinner and
///   one line of text — nothing else;
/// - transfers: a fixed-width block with title + percent, a thin bar,
///   and one caption line (bytes · rate · time left).
struct WinlinkExchangeProgressView: View {

    @ObservedObject var runner: WinlinkSessionRunner

    var body: some View {
        if let progress = runner.progress, progress.bytesTotal > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                transferBlock(progress, now: timeline.date)
            }
        } else if runner.isRunning {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(runner.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 280, alignment: .trailing)
        }
    }

    private func transferBlock(_ progress: WinlinkExchangeProgress, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: progress.kind == .receiving ? "arrow.down" : "arrow.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title(for: progress))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let fraction = progress.fraction {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: progress.fraction ?? 0)
                .controlSize(.small)

            Text(detailLine(for: progress, now: now))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(width: 250)
        .help(WinlinkCopy.connectExchangeTooltip)
        .accessibilityElement(children: .combine)
    }

    private func title(for progress: WinlinkExchangeProgress) -> String {
        let direction = progress.kind == .receiving ? "Receiving" : "Sending"
        if let subject = progress.subject, !subject.isEmpty {
            return "\(direction) “\(subject)”"
        }
        if let mid = progress.mid {
            return "\(direction) \(mid)"
        }
        return direction
    }

    private func detailLine(for progress: WinlinkExchangeProgress, now: Date) -> String {
        var parts = ["\(byteText(progress.bytesDone)) of \(byteText(progress.bytesTotal))"]
        if let rate = progress.bytesPerSecond(now: now), rate >= 1 {
            parts.append("\(byteText(Int(rate)))/s")
        }
        if let seconds = progress.estimatedSecondsRemaining(now: now), seconds > 2 {
            parts.append("\(timeText(seconds)) left")
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
