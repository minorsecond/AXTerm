import SwiftUI

/// How busy the channel is, and whether the beacon path suits it.
///
/// Presented together and with the workings shown. The recommendation is a
/// judgement made from four measurements and two thresholds, and an operator
/// who can see all six can overrule it on local knowledge this has no way of
/// holding — that a digipeater is about to go off the air for a repair, that
/// tonight is a net, that the path is set for an event next week.
struct APRSChannelPathView: View {

    let report: APRSChannelReport
    var onRefresh: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Recommendation") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(report.recommendation.headline, systemImage: verdictSymbol)
                            .font(.headline)
                            .foregroundStyle(verdictColor)
                        Text("Your path: \(report.pathDescription)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    ForEach(Array(report.recommendation.reasons.enumerated()), id: \.offset) { _, reason in
                        Label {
                            Text(reason).font(.callout)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 4))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section("Channel") {
                    measurement("Traffic",
                                String(format: "%.1f frames a minute", report.load.framesPerMinute),
                                "Over the last \(Int(report.load.window / 60)) minutes, on the radios carrying APRS.")
                    measurement("Occupancy",
                                String(format: "%.1f%%", report.load.occupancyIncludingKeyUp * 100),
                                "Share of the air in use. \(String(format: "%.1f%%", report.load.occupancy * 100)) is "
                                + "data measured from the frames themselves; the rest is an allowance of "
                                + "\(Int(APRSChannelLoad.assumedKeyUp * 1000)) ms key-up per frame, which belongs to the "
                                + "sending station and cannot be read off a received frame. Collisions climb steeply "
                                + "past about \(Int(APRSChannelLoad.busyOccupancy * 100))%.")
                    measurement("Repeats",
                                String(format: "%.0f%%", report.load.duplicateShare * 100),
                                "Frames that were another copy of one already heard, by a different path. This is the "
                                + "network repeating itself rather than new information.")
                }

                if !report.advice.digipeaters.isEmpty {
                    Section("Digipeaters repeating you (\(report.advice.digipeaters.count))") {
                        ForEach(report.advice.digipeaters) { digi in
                            HStack {
                                Text(digi.callsign).font(.callout.monospaced())
                                Spacer()
                                Text(digi.hearsUsDirect
                                     ? "hears you direct"
                                     : "only after \(digi.shallowestHop) more hop\(digi.shallowestHop == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(digi.hearsUsDirect ? .secondary : Color.orange)
                            }
                        }
                    }
                }

                Section {
                    Text(report.advice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("What this is measured from")
                }
            }
            .navigationTitle("Channel & Path")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let onRefresh {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            onRefresh()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 520)
    }

    private var verdictSymbol: String {
        switch report.recommendation.verdict {
        case .keep: return "checkmark.circle"
        case .considerShortening: return "arrow.down.circle"
        case .notEnough: return "questionmark.circle"
        }
    }

    private var verdictColor: Color {
        switch report.recommendation.verdict {
        case .keep: return .green
        case .considerShortening: return .orange
        case .notEnough: return .secondary
        }
    }

    @ViewBuilder
    private func measurement(_ title: String, _ value: String, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.callout.monospacedDigit().weight(.medium))
            }
            Text(help)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }
}
