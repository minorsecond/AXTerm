import SwiftUI

/// One session in the list.
struct SessionHistoryRow: View {

    let session: TerminalSession
    /// "From K0EPI-7 on Ross's Mac" for a session another device recorded;
    /// nil for this device's own. On the row itself, not only in the section
    /// heading, because a row is what gets read, copied and remembered.
    var originLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let originLabel {
                Label(originLabel, systemImage: "laptopcomputer.and.iphone")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Recorded elsewhere. \(originLabel)")
            }
            HStack(spacing: 6) {
                Text(session.correspondent)
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                // Only when the two differ, which is what a relay looks like:
                // dialled DRLNOD, talked to BBSCBH.
                if session.relayDestination != nil {
                    Text("via \(session.remote)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                OutcomeBadge(outcome: session.outcome)
            }

            HStack(spacing: 6) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                if let duration = session.duration, duration >= 1 {
                    Text("\u{00B7} \(Self.durationText(duration))")
                }
                if !session.via.isEmpty {
                    Text("\u{00B7} \(session.via.joined(separator: " \u{2192} "))")
                        .foregroundStyle(.purple)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !session.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(session.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Short enough for a list: minutes and seconds, hours when there were
    /// any.
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }
}

/// How a session ended, coloured by what it says about the path.
///
/// A refusal is the far end answering and took a decoded frame to produce, so
/// it is not drawn in the same red as nothing answering at all.
struct OutcomeBadge: View {

    let outcome: TerminalSession.Outcome

    var body: some View {
        Text(outcome.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .help(help)
    }

    private var tint: Color {
        switch outcome {
        case .live: return .blue
        case .closed: return .green
        case .refused: return .orange
        case .timedOut: return .secondary
        case .lost: return .red
        }
    }

    private var help: String {
        switch outcome {
        case .live: return "Still connected."
        case .closed: return "Ended normally, by one side or the other."
        case .refused:
            return "The far end answered and declined. That took a decoded frame, so "
                + "the station heard us."
        case .timedOut:
            return "Nothing answered. Silence is not a refusal: it says nothing about "
                + "whether the station is there."
        case .lost: return "The link dropped without a disconnect."
        }
    }
}
