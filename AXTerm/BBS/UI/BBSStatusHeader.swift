//
//  BBSStatusHeader.swift
//  AXTerm
//

import SwiftUI

/// Whether the mailbox is reachable, answered in one glance.
///
/// A mailbox is off the air far more often than it is on, and the two states
/// that matter are not "on/off" but "on" versus "off *for a reason you did not
/// choose*" — Winlink holding the port, another device holding the callsign.
/// Those refusals are shown here, in the operator's own view, rather than
/// discovered later from a caller complaining they got no answer.
struct BBSStatusHeader: View {
    @ObservedObject var service: BBSService
    @ObservedObject var settings: BBSSettings

    private var refusal: String? { service.currentRefusal() }
    private var isReachable: Bool { settings.onAir && refusal == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isReachable ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 10, height: 10)
                    .overlay {
                        if isReachable {
                            Circle().stroke(Color.green.opacity(0.35), lineWidth: 6)
                        }
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isReachable
                         ? "On air as \(service.answeringCallsign)"
                         : "Off air")
                        .font(.headline)
                    // The explanation hangs here rather than on the switch.
                    // `.explain` wraps what it decorates in a container of its
                    // own, and on iOS that stops a `Toggle` responding to
                    // taps at all — the switch drew, the popover worked, and
                    // the mailbox could not be put on the air. A caption is
                    // inert, so decorating it costs nothing.
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .explain(onAirExplanation)
                }

                Spacer()

                Toggle("On air", isOn: $settings.onAir)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    #if os(macOS)
                    .help(settings.onAir
                          ? "Stop answering calls"
                          : "Answer calls while AXTerm is running")
                    #endif
                    .accessibilityLabel("Mailbox on air")
                    .accessibilityHint(onAirExplanation)
            }

            // Named separately from the subtitle: a mailbox switched on that
            // still cannot answer is the confusing case this exists for.
            if settings.onAir, let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// Why this switch matters, in the words CLAUDE.md §11 asks for: what the
    /// value means, not what the control is called.
    private var onAirExplanation: String {
        settings.onAir
            ? "The mailbox answers calls while AXTerm is running and registers its "
              + "address with the station. Switching it off stops both: callers get no "
              + "answer at all."
            : "Switch on to answer calls while AXTerm is running. Answering means "
              + "transmitting with nobody present, which in the US is automatic control "
              + "— which is why it is off until you say otherwise."
    }

    private var subtitle: String {
        if !settings.onAir {
            return "Nobody can reach the mailbox. Callers get no answer."
        }
        if refusal != nil { return "Switched on, but not answering." }
        if let live = service.live {
            return "Serving \(live.callsign)."
        }
        return "Answering calls while AXTerm is running."
    }
}
