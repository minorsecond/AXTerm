import SwiftUI

/// Past exchanges, and what each one carried.
///
/// Every session already left a row saying what it cost. Until now those
/// rows were only ever read in aggregate — for readiness and gateway hours —
/// so an operator asking "what happened on that one" had nowhere to look.
///
/// The list leads with duration and outcome because those are the two things
/// looked for: whether the airtime bought anything, and if not, why.
struct WinlinkSessionHistoryView: View {

    let store: WinlinkStore?
    /// Pre-selects one session — the path in from a message that wants to
    /// show the exchange that carried it.
    var focusSessionID: Int64?

    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [WinlinkSessionSummary] = []
    @State private var selection: Int64?
    @State private var carried: [String] = []
    @State private var solar: SolarConditions?

    var body: some View {
        NavigationSplitView {
            List(summaries, selection: $selection) { summary in
                row(summary).tag(summary.id)
            }
            .navigationTitle("Sessions")
            .frame(minWidth: 280)
        } detail: {
            if let summary = summaries.first(where: { $0.id == selection }) {
                detail(summary)
            } else {
                ContentUnavailableView(
                    "Select a session",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Every exchange records what it cost and what it carried."))
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear(perform: load)
        .onChange(of: selection) { _, _ in
            loadCarried()
            loadSolar()
        }
    }

    private func row(_ summary: WinlinkSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: summary.succeeded
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.succeeded ? .green : .orange)
                    .font(.caption)
                Text(summary.log.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(summary.durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(summary.linkText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func detail(_ summary: WinlinkSessionSummary) -> some View {
        Form {
            Section("Outcome") {
                LabeledContent("Result", value: summary.outcomeText)
                LabeledContent("Started") {
                    Text(summary.log.startedAt, format: .dateTime
                        .year().month().day().hour().minute().second())
                }
                LabeledContent("Took", value: summary.durationText)
                LabeledContent("Link", value: summary.linkText)
                LabeledContent("Transport", value: summary.log.transport.uppercased())
            }

            Section("Traffic") {
                LabeledContent("Messages", value: summary.trafficText)
                LabeledContent("Bytes", value: "\(summary.log.bytesSent) sent · "
                                             + "\(summary.log.bytesReceived) received")
                if let rate = summary.bytesPerSecond {
                    LabeledContent("Throughput", value: String(format: "%.0f B/s", rate))
                } else {
                    // Saying why beats an empty row: a session too short to
                    // measure is a fact about the session.
                    LabeledContent("Throughput", value: "too short to measure")
                }
            }

            if let grid = summary.log.obsGrid {
                Section("Where you were") {
                    LabeledContent("Grid", value: grid)
                    if let source = summary.log.obsSource {
                        LabeledContent("Source", value: source)
                    }
                    Text("RF reachability is a property of both ends, so a session run "
                         + "from somewhere else says little about this link.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Space weather that day") {
                if let solar {
                    if let flux = solar.solarFlux {
                        LabeledContent("Solar flux", value: String(format: "%.0f", flux))
                    }
                    if let k = solar.kIndex {
                        LabeledContent("Kp (day max)") {
                            Text(SolarConditions.geomagneticDescription(kIndex: k)
                                    .map { "\(String(format: "%.1f", k)) — \($0)" }
                                 ?? String(format: "%.1f", k))
                        }
                    }
                    LabeledContent("Source", value: solar.source)
                    // What these numbers are allowed to explain depends on
                    // the path this session actually used — and when the
                    // frequency was not recorded, on saying so.
                    if let note = SolarBandRelevance.note(
                        frequencyHz: summary.log.frequencyHz,
                        transport: summary.log.transport,
                        kIndex: solar.kIndex) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Not recorded for this day. Conditions are fetched when a session "
                         + "runs and there is a network to ask.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Carried") {
                if carried.isEmpty {
                    Text(summary.log.messagesReceived > 0
                         ? "This exchange predates message linking, so what it carried was not recorded."
                         : "Nothing came in on this exchange.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(carried, id: \.self) { mid in
                        Text(mid).font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func load() {
        summaries = ((try? store?.sessionLogs(limit: 200)) ?? []).map(WinlinkSessionSummary.init)
        if let focusSessionID, summaries.contains(where: { $0.id == focusSessionID }) {
            selection = focusSessionID
        } else if selection == nil {
            selection = summaries.first?.id
        }
        loadCarried()
        loadSolar()
    }

    private func loadSolar() {
        guard let selection,
              let summary = summaries.first(where: { $0.id == selection }) else {
            solar = nil
            return
        }
        let day = SolarConditionsService.day(containing: summary.log.startedAt)
        solar = (try? store?.solarConditions(forDay: day)) ?? nil
    }

    private func loadCarried() {
        guard let selection else { carried = []; return }
        carried = ((try? store?.messageIDs(forSessionLog: selection)) ?? []).sorted()
    }
}
