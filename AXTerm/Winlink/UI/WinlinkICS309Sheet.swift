import SwiftUI

/// Generates an ICS-309 Communications Log from the traffic already in
/// the mailbox.
///
/// Every field defaults to something usable, because the moment this is
/// needed is the moment nobody wants to fill in a form: the operational
/// period defaults to the last 24 hours, and the operator and station
/// identity come from the station profile.
struct WinlinkICS309Sheet: View {

    /// Every non-draft message on hand. Filtering to the operational
    /// period happens in `ICS309Log.build`.
    let messages: [WinlinkMessageSummary]
    let defaultOperatorName: String
    let defaultStationId: String

    @Environment(\.dismiss) private var dismiss

    @State private var pendingExport: ExportableFile?
    @State private var incidentName = ""
    @State private var taskName = ""
    @State private var operatorName = ""
    @State private var stationId = ""
    @State private var periodStart = Date().addingTimeInterval(-24 * 3600)
    @State private var periodEnd = Date()
    @State private var saveError: String?

    private var log: ICS309Log {
        ICS309Log.build(
            messages: messages,
            incidentName: incidentName,
            periodStart: periodStart,
            periodEnd: periodEnd,
            taskName: taskName,
            operatorName: operatorName,
            stationId: stationId)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("ICS-309 Communications Log", systemImage: "list.clipboard")
                    .font(.headline)
                Spacer()
            }
            .padding(12)
            .help("The message log a served agency asks for after an activation. Built from traffic already stored — unlike almost everything else, this cannot be reconstructed later, so it is worth exporting while the incident is fresh.")
            Divider()

            Form {
                Section {
                    TextField("Incident name", text: $incidentName,
                              prompt: Text("e.g. Boulder County Flood"))
                    TextField("Radio net name / task", text: $taskName,
                              prompt: Text("e.g. Winlink P2P Net"))
                }
                Section {
                    DatePicker("Period start", selection: $periodStart)
                    DatePicker("Period end", selection: $periodEnd)
                }
                .help("Only traffic inside this window is logged. Times print in UTC, which is what the traffic carries and what an agency can reconcile across several stations.")
                Section {
                    TextField("Operator name", text: $operatorName)
                    TextField("Station ID", text: $stationId)
                        .font(.body.monospaced())
                }
            }
            .formStyle(.grouped)
            .frame(height: 260)

            Divider()
            preview
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 620)
        .onAppear {
            if operatorName.isEmpty { operatorName = defaultOperatorName }
            if stationId.isEmpty { stationId = defaultStationId }
        }
    }

    private var preview: some View {
        ScrollView {
            Text(log.renderPlainText())
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(log.entries.count) message\(log.entries.count == 1 ? "" : "s") in period")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button("Copy") {
                ClipboardWriter.copy(log.renderPlainText())
            }
            .explain("Copies the log as plain text — the shape that survives being pasted into a message.",
                     showsIndicator: false)
            Button("Save CSV\u{2026}") { save(text: log.renderCSV(), extension: "csv") }
                .explain("Comma-separated, RFC 4180 quoted, for spreadsheets and agency ingest.",
                         showsIndicator: false)
            Button("Save Text\u{2026}") { save(text: log.renderPlainText(), extension: "txt") }
                .keyboardShortcut(.defaultAction)
            Button("Close") { dismiss() }
        }
        .padding(12)
        .exportFile($pendingExport) { saveError = $0 }
    }

    /// Names the file after the station and the end of the operational
    /// period, so a folder of them from an activation sorts and reads
    /// without opening any of them.
    private func save(text: String, extension ext: String) {
        let stamp = ICS309Log.timestamp(periodEnd)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let station = stationId.isEmpty ? "station" : stationId
        saveError = nil
        pendingExport = ExportableFile(
            name: "ICS-309-\(station)-\(stamp).\(ext)",
            data: Data(text.utf8))
    }
}
