//
//  BBSCallersPane.swift
//  AXTerm
//

import SwiftUI

// The mailbox UI is macOS-only, like the window layout it lives in. The shell,
// the store and the service are platform-neutral, so an iOS view can be added
// later without touching anything below this layer.
#if os(macOS)

/// Who called, and what they did.
///
/// The operator is asleep for most of what the mailbox does, so this is the
/// view that actually answers "what happened overnight". A caller who reads a
/// bulletin and leaves nothing behind is invisible in the message list and
/// perfectly visible here.
struct BBSCallersPane: View {
    @ObservedObject var service: BBSService
    let now: Date

    var body: some View {
        if service.calls.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "phone.badge.waveform")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("Nobody has called yet").foregroundStyle(.secondary)
                Text("Calls are logged whenever the mailbox is on air, "
                     + "including ones that left nothing behind.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(service.calls) { call in
                row(call)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ call: BBSCall) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: call.isLive ? "dot.radiowaves.left.and.right" : "phone.down")
                .font(.caption)
                .foregroundStyle(call.isLive ? Color.green : .secondary)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(call.callsign)
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.medium)
                    Text(call.connectedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(duration(call))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if call.actions.isEmpty {
                    Text(call.isLive ? "connected" : "looked around, left nothing")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(call.actions.enumerated()), id: \.offset) { _, action in
                        Text(action)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Worth distinguishing: a caller who said B got what they came
                // for, and one whose link dropped may not have.
                if call.endedUnexpectedly && !call.isLive {
                    Label("link dropped", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func duration(_ call: BBSCall) -> String {
        if call.isLive {
            return BBSLiveCallPanel.elapsed(from: call.connectedAt, to: now)
        }
        guard let seconds = call.duration else { return "" }
        return BBSLiveCallPanel.elapsed(seconds)
    }
}
#endif
