import SwiftUI

/// The "who can hear me" UI. Pressing Start floods **one** unaddressed `?APRS?`
/// general query; every APRS station that answers within the window can hear
/// you, shown direct or via a digipeater as the replies land. The scope
/// segment (all / infrastructure / moving) filters what's shown — a general
/// query reaches everyone in earshot, so it can't be aimed, only filtered.
struct APRSWhoCanHearMeView: View {
    @ObservedObject var probe: APRSReachabilityProbe
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Show", selection: $probe.scope) {
                    ForEach(APRSProbeScope.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Text(statusLine).font(.callout).foregroundStyle(.secondary).padding(.horizontal)

                List {
                    let answered = probe.scopedResponders.filter { $0.evidence == .answered }
                    let anyway = probe.scopedResponders.filter { $0.evidence != .answered }
                    if !answered.isEmpty {
                        Section("\(answeredTitle) (\(answered.count))") {
                            ForEach(answered) { row(for: $0) }
                        }
                    }
                    // Kept, and kept apart. These stations were heard inside
                    // the window and may well have answered — but they beacon
                    // often enough that they would have transmitted anyway, so
                    // counting them as replies is counting the channel's own
                    // traffic as evidence about us.
                    if !anyway.isEmpty {
                        Section("Heard, but beaconing anyway (\(anyway.count))") {
                            ForEach(anyway) { row(for: $0) }
                        }
                    }
                    let silent = probe.scopedSilent
                    if !silent.isEmpty {
                        Section("Heard earlier, silent now (\(silent.count))") {
                            ForEach(silent, id: \.self) { Text($0).foregroundStyle(.secondary) }
                        }
                    }
                    if answered.isEmpty && anyway.isEmpty && silent.isEmpty {
                        Text(emptyLine).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Who Can Hear Me?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { probe.cancel(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if probe.status == .listening {
                        Button("Stop") { probe.cancel() }
                    } else {
                        Button(probe.sentAt == nil ? "Start" : "Again") {
                            // The same question, asked the same distance.
                            probe.start(query: probe.query, scope: probe.scope,
                                        reach: probe.reach)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 420)
    }

    private var statusLine: String {
        switch probe.status {
        case .idle:
            if probe.transmitFailed {
                // Two different failures, and the operator fixes them in
                // different places: nothing took the frame at all, or a radio
                // took it and then couldn't key.
                if let reason = probe.transmitFailureReason {
                    return "The query didn't reach the air — the radio reported: \(reason). Nothing was listened for, so try again once the radio can transmit."
                }
                return "Couldn't transmit — no connected radio has APRS turned on. Enable APRS for a radio in Settings ▸ Radios (a radio that beacons an APRS position already counts), and make sure it's connected."
            }
            return probe.sentAt == nil
                ? "Sends one general query on your APRS radio(s) and lists who answers — direct or via a digipeater. One transmission, Xastir-style."
                : "Stopped. \(probe.scopedAnsweringResponders.count) answered."
        case .listening:
            return "Listening… \(probe.scopedAnsweringResponders.count) answered so far."
        case .done:
            let answered = probe.scopedAnsweringResponders.count
            let direct = probe.scopedAnsweringResponders.filter(\.direct).count
            let anyway = probe.scopedResponders.count - answered
            var line = probe.reach == .wide
                ? "Done, asked \(APRSProbeReach.wide.label.lowercased()). \(answered) answered — reachable, though not necessarily in direct earshot."
                : "Done. \(answered) answered and can hear you directly or via a digi (\(direct) direct)."
            if anyway > 0 {
                line += " \(anyway) more transmitted inside the window but beacon often enough to have done so anyway."
            }
            return line
        }
    }

    /// What an answer proves depends on how far the question went. A
    /// digipeated query is answered by stations that cannot hear this one at
    /// all, so calling that section "can hear you" would be a lie the results
    /// panel tells every time.
    private var answeredTitle: String {
        probe.reach == .wide ? "Answered" : "Answered — can hear you"
    }

    private var emptyLine: String {
        switch probe.status {
        case .listening: return "Waiting for replies…"
        default: return "No APRS stations of this kind have answered. Press Start to send a query."
        }
    }

    @ViewBuilder
    private func row(for responder: APRSReachabilityProbe.Responder) -> some View {
        HStack {
            Text(responder.callsign)
            if responder.evidence != .answered {
                Text("beacons often")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("This station transmits often enough that landing inside the "
                          + "listening window says nothing about the query. It may have "
                          + "answered; there is no way to tell from a broadcast position.")
            }
            Spacer()
            Label(responder.direct ? "direct" : "via digi",
                  systemImage: responder.direct ? "dot.radiowaves.left.and.right" : "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(responder.direct ? .green : .orange)
        }
    }
}
