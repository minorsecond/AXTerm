//
//  BBSLiveCallPanel.swift
//  AXTerm
//

import SwiftUI

// The mailbox UI is macOS-only, like the window layout it lives in. The shell,
// the store and the service are platform-neutral, so an iOS view can be added
// later without touching anything below this layer.
#if os(macOS)

/// The caller's session as it happens, exactly as they see it.
///
/// The one thing a hardware mailbox can never show its sysop. It is also the
/// fastest way to find out that a banner reads badly or a command confuses
/// people — you watch somebody hit it.
struct BBSLiveCallPanel: View {
    @ObservedObject var service: BBSService
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            transcript
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.green.opacity(0.4), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(.green).frame(width: 7, height: 7)
            Text(service.live?.callsign ?? "")
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
            if let started = service.live?.startedAt {
                Text(Self.elapsed(from: started, to: now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Disconnect") { service.shutdown(reason: "sysop ended the session") }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(service.transcript) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: line.direction))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 180)
            .onChange(of: service.transcript.count) {
                guard let last = service.transcript.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func color(for direction: BBSService.TranscriptLine.Direction) -> Color {
        switch direction {
        case .fromCaller: .accentColor
        case .toCaller: .primary
        case .note: .secondary
        }
    }

    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func elapsed(from start: Date, to end: Date) -> String {
        elapsed(end.timeIntervalSince(start))
    }
}
#endif
