//
//  BBSLiveCallPanel.swift
//  AXTerm
//

import SwiftUI

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
        .background(Color(platform: .platformTextBackground))
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
                Text(BBSElapsed.format(from: started, to: now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Disconnect") { service.shutdown(reason: "sysop ended the session") }
                .controlSize(.small)
                // Not silence: a caller whose station vanishes mid-session
                // retries into an address that stopped existing.
                // Indicator on: an explanation with none takes the tap for
                // itself, and this one is attached to a button.
                .explain("Sends the caller a closing line and a DISC, so their "
                         + "software knows the session ended rather than retrying "
                         + "into a station that went quiet.")
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

}
