import SwiftUI

/// Popdown exchange console: the live wire transcript of the B2F
/// conversation (TX/RX lines and protocol events), monospaced, with
/// auto-scroll. Persists after the exchange ends so a result can be
/// reviewed later; cleared when the next exchange starts.
struct WinlinkExchangeConsoleView: View {

    @ObservedObject var runner: WinlinkSessionRunner

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            if runner.transcript.isEmpty {
                Text("No exchange yet — the conversation with the gateway will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(runner.transcript) { entry in
                                row(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
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
        .frame(height: 170)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .help("The raw B2F conversation with the gateway: sent lines (→), received lines (←), and session events. Binary message bodies are summarized by size.")
    }

    private func row(_ entry: WinlinkTranscriptEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
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
