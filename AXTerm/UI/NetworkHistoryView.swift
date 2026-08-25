import SwiftUI

/// How one remote observation reads on screen.
///
/// Split out so the wording is testable. The labelling is the safety
/// feature here, not decoration: an operator who mistakes another station's
/// observations for their own will draw wrong conclusions about what their
/// own radio can reach, and the screen is the last place that can prevent
/// it.
nonisolated enum NetworkHistoryRow {

    /// Never "N0CVL-10 · 7 frames" on its own — always whose ears heard it.
    static func attribution(_ payload: StationActivityPayload) -> String {
        let station = payload.provenance.station
        if let grid = payload.provenance.gridSquare, !grid.isEmpty {
            return "Heard by \(station) · \(grid)"
        }
        return "Heard by \(station)"
    }

    static func activity(_ payload: StationActivityPayload,
                         now: Date = Date()) -> String {
        let frames = payload.frameCount == 1 ? "1 frame" : "\(payload.frameCount) frames"
        return "\(frames) · last \(relative(payload.lastHeard, now: now))"
    }

    /// Deliberately coarse. These observations arrive by CloudKit, which is
    /// unhurried, so a to-the-second timestamp would imply a precision the
    /// transport does not have.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return "just now" }
        if seconds < 3600 { return "within the hour" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    /// Grouped by the station that heard them, because that is the unit the
    /// operator reasons about: "what can the home rig hear" is a different
    /// question from "what can this handheld hear", and a merged list would
    /// answer neither.
    static func grouped(_ payloads: [StationActivityPayload]) -> [(station: String, entries: [StationActivityPayload])] {
        Dictionary(grouping: payloads, by: { $0.provenance.station })
            .map { (station: $0.key, entries: $0.value.sorted { $0.lastHeard > $1.lastHeard }) }
            .sorted { $0.station < $1.station }
    }
}

/// What the operator's *other* stations have heard.
///
/// A separate screen on purpose. These are observations from another antenna
/// in another place; showing them beside the local ones would invite exactly
/// the comparison that is invalid, and folding them together would corrupt
/// the routing metrics CLAUDE.md requires to stay evidence-based.
struct NetworkHistoryView: View {

    let observations: [StationActivityPayload]

    var body: some View {
        List {
            Section {
                Label("These are observations from your other stations, not from this one. They are shown for reference and never affect this station's routing or link quality.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(NetworkHistoryRow.grouped(observations), id: \.station) { group in
                Section(group.station) {
                    ForEach(group.entries, id: \.callsign) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.callsign)
                                .font(.body.monospaced())
                            Text(NetworkHistoryRow.activity(entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(NetworkHistoryRow.attribution(entry))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .explain("\(entry.callsign) was heard \(entry.frameCount) times by \(entry.provenance.station), not by this station. Airtime \(String(format: "%.1f", entry.airtimeSeconds))s. Reference only — it is not evidence about what this radio can reach.",
                                 showsIndicator: false)
                    }
                }
            }
        }
        .overlay {
            if observations.isEmpty {
                ContentUnavailableView(
                    "Nothing from your other stations",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("When another AXTerm station syncs, what it heard while this one was away appears here."))
            }
        }
    }
}
