import SwiftUI

/// Post-session sequence diagram: the B2F exchange rendered as arrows
/// between two lifelines (Us | Gateway), grouped into protocol phases.
/// Built from the same transcript the console shows.
struct WinlinkExchangeReplayView: View {

    let transcript: [WinlinkTranscriptEntry]
    let gatewayName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Session replay")
                    .font(.headline)
                Spacer()
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            HStack {
                lifelineLabel("This station")
                Spacer()
                lifelineLabel(gatewayName)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 6)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 380, idealHeight: 520)
    }

    // MARK: - Row model

    private struct ReplayRow: Identifiable {
        enum Kind {
            case sent(String)
            case received(String)
            case event(String)
            /// N consecutive binary blocks collapsed into one arrow.
            case blockBurst(count: Int, bytes: Int, direction: WinlinkTranscriptEntry.Direction)
        }
        let id = UUID()
        let timestamp: Date
        let kind: Kind
    }

    /// Collapses runs of binary-block lines ("‹N bytes of …›") so a 43 KB
    /// transfer reads as one thick arrow, not 300 rows.
    private var rows: [ReplayRow] {
        var result: [ReplayRow] = []
        var burstCount = 0
        var burstBytes = 0
        var burstStart: Date?
        var burstDirection: WinlinkTranscriptEntry.Direction = .received

        func flushBurst() {
            guard burstCount > 0, let start = burstStart else { return }
            result.append(ReplayRow(
                timestamp: start,
                kind: .blockBurst(count: burstCount, bytes: burstBytes, direction: burstDirection)))
            burstCount = 0
            burstBytes = 0
            burstStart = nil
        }

        for entry in transcript {
            if let bytes = Self.binaryChunkBytes(entry.text), entry.direction != .event {
                if burstCount == 0 { burstStart = entry.timestamp; burstDirection = entry.direction }
                burstCount += 1
                burstBytes += bytes
                continue
            }
            flushBurst()
            switch entry.direction {
            case .sent: result.append(ReplayRow(timestamp: entry.timestamp, kind: .sent(entry.text)))
            case .received: result.append(ReplayRow(timestamp: entry.timestamp, kind: .received(entry.text)))
            case .event: result.append(ReplayRow(timestamp: entry.timestamp, kind: .event(entry.text)))
            }
        }
        flushBurst()
        return result
    }

    static func binaryChunkBytes(_ text: String) -> Int? {
        // Matches the console's wire heuristic: "‹123 bytes of compressed message data›"
        guard text.hasPrefix("‹"), text.contains(" bytes") else { return nil }
        let digits = text.dropFirst().prefix { $0.isNumber }
        return Int(digits)
    }

    private var summaryLine: String {
        let sent = transcript.filter { $0.direction == .sent }.count
        let received = transcript.filter { $0.direction == .received }.count
        return "\(sent) sent · \(received) received"
    }

    // MARK: - Rendering

    private func lifelineLabel(_ name: String) -> some View {
        Text(name)
            .font(.caption.weight(.semibold).monospaced())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    @ViewBuilder
    private func rowView(_ row: ReplayRow) -> some View {
        switch row.kind {
        case .sent(let text):
            arrowRow(time: row.timestamp, label: text, color: .blue, pointsRight: true, thick: false)
        case .received(let text):
            arrowRow(time: row.timestamp, label: text, color: .green, pointsRight: false, thick: false)
        case .event(let text):
            HStack {
                Spacer()
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.08)))
                Spacer()
            }
            .padding(.vertical, 3)
        case .blockBurst(let count, let bytes, let direction):
            arrowRow(
                time: row.timestamp,
                label: "\(count) binary blocks · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary))",
                color: direction == .sent ? .blue : .green,
                pointsRight: direction == .sent,
                thick: true)
        }
    }

    private func arrowRow(time: Date, label: String, color: Color, pointsRight: Bool, thick: Bool) -> some View {
        HStack(spacing: 8) {
            Text(TimeDisplay.timeString(time))
                .font(.caption2.monospaced())
                .foregroundStyle(.quaternary)
                .frame(width: 52, alignment: .leading)

            ZStack {
                ArrowShape(pointsRight: pointsRight)
                    .stroke(color, style: StrokeStyle(lineWidth: thick ? 3 : 1.2, lineCap: .round, lineJoin: .round))
                    .frame(height: 12)
                Text(label)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4).fill(Color(platform: .platformWindowBackground)))
            }
        }
        .padding(.vertical, 2)
    }

    private struct ArrowShape: Shape {
        let pointsRight: Bool
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let y = rect.midY
            path.move(to: CGPoint(x: rect.minX + 28, y: y))
            path.addLine(to: CGPoint(x: rect.maxX - 28, y: y))
            let tipX = pointsRight ? rect.maxX - 28 : rect.minX + 28
            let back: CGFloat = pointsRight ? -7 : 7
            path.move(to: CGPoint(x: tipX + back, y: y - 4))
            path.addLine(to: CGPoint(x: tipX, y: y))
            path.addLine(to: CGPoint(x: tipX + back, y: y + 4))
            return path
        }
    }
}
