//
//  DiagnosticsView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published var events: [AppEventRecord] = []
    @Published var copyFeedback: String?
    /// The report waiting to be filed by the operator; see `.exportFile`.
    @Published var pendingExport: ExportableFile?
    @Published var exportError: String?

    private let settings: AppSettingsStore
    private let eventStore: EventLogStore?
    private let displayLimit = 2_000
    private let exportLimit = 1_000

    init(settings: AppSettingsStore, eventStore: EventLogStore?) {
        self.settings = settings
        self.eventStore = eventStore
    }

    func load() {
        guard let eventStore else {
            events = []
            return
        }
        let limit = min(settings.eventRetentionLimit, displayLimit)
        DispatchQueue.global(qos: .utility).async { [eventStore] in
            let records = (try? eventStore.loadRecent(limit: limit)) ?? []
            Task { @MainActor in
                self.events = records.reversed()
            }
        }
    }

    func copyDiagnostics() {
        makeReportJSON(limit: exportLimit) { [weak self] json in
            guard let json else { return }
            ClipboardWriter.copy(json)
            self?.showCopyFeedback()
        }
    }

    /// Hands the diagnostics report to the operator to file.
    ///
    /// Failure is reported, not swallowed: the export is something the
    /// operator explicitly asked for, and a silent failure looked exactly
    /// like a successful save.
    func exportDiagnostics() {
        makeReportJSON(limit: exportLimit) { [weak self] json in
            guard let json else { return }
            self?.pendingExport = ExportableFile(name: "AXTerm-Diagnostics.json",
                                                 data: Data(json.utf8))
        }
    }

    private func makeReportJSON(limit: Int, completion: @escaping (String?) -> Void) {
        let report = DiagnosticsExporter.makeReport(settings: settings, events: Array(events.suffix(limit)))
        completion(DiagnosticsExporter.makeJSON(report: report))
    }

    private func showCopyFeedback() {
        copyFeedback = "Copied"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copyFeedback = nil
        }
    }
}

struct DiagnosticsView: View {
    @StateObject private var model: DiagnosticsViewModel

    init(settings: AppSettingsStore, eventStore: EventLogStore?) {
        _model = StateObject(wrappedValue: DiagnosticsViewModel(settings: settings, eventStore: eventStore))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            #if os(iOS)
            touchList
            #else
            Table(model.events) {
                TableColumn("Time") { event in
                    Text(Self.timeFormatter.string(from: event.createdAt))
                        .foregroundStyle(.secondary)
                }
                TableColumn("Level") { event in
                    Text(event.level.rawValue.uppercased())
                }
                TableColumn("Category") { event in
                    Text(event.category.rawValue)
                        .foregroundStyle(.secondary)
                }
                TableColumn("Message") { event in
                    Text(event.message)
                        .lineLimit(2)
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 400)
        #endif
        .task {
            model.load()
        }
        .exportFile($model.pendingExport) { model.exportError = $0 }
        .alert("Export failed", isPresented: Binding(
            get: { model.exportError != nil },
            set: { if !$0 { model.exportError = nil } })) {
            Button("OK") { model.exportError = nil }
        } message: {
            Text(model.exportError ?? "")
        }
    }

#if os(iOS)
    /// The same events as a touch list.
    ///
    /// `Table` renders only its first column on iOS, so this screen showed a
    /// column of bare timestamps with no level, category or message — the
    /// diagnostics view being the one place that has to be readable when
    /// something has gone wrong. Same trap as the mailbox and the address
    /// book; this was the last one left.
    private var touchList: some View {
        Group {
            if model.events.isEmpty {
                ContentUnavailableView(
                    "No events",
                    systemImage: "checkmark.seal",
                    description: Text("Nothing has been logged on this device yet."))
            } else {
                List(model.events, id: \.id) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(event.level.rawValue.uppercased())
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(tint(for: event.level).opacity(0.18), in: Capsule())
                                .foregroundStyle(tint(for: event.level))
                            Text(event.category.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 6)
                            Text(Self.timeFormatter.string(from: event.createdAt))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Text(event.message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.plain)
            }
        }
    }

    /// Severity has to survive the loss of the colour-coded column.
    private func tint(for level: AppEventRecord.Level) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
#endif

    private var header: some View {
        HStack {
            Text("Diagnostics")
                .font(.headline)

            Spacer()

            Text("\(model.events.count) events")
                .foregroundStyle(.secondary)
                .font(.caption)

            if let feedback = model.copyFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Copy Diagnostics") {
                model.copyDiagnostics()
            }
            .buttonStyle(.bordered)

            Button("Export…") {
                model.exportDiagnostics()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.bar)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

#Preview {
    DiagnosticsView(settings: AppSettingsStore(), eventStore: nil)
}
