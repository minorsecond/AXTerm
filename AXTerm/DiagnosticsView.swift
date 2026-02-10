//
//  DiagnosticsView.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/2/26.
//

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    @Published var events: [AppEventRecord] = []
    @Published var copyFeedback: String?

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

    func exportDiagnostics() {
        makeReportJSON(limit: exportLimit) { json in
            guard let json else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "AXTerm-Diagnostics.json"
            panel.canCreateDirectories = true
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try json.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    return
                }
            }
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
        }
        .frame(minWidth: 700, minHeight: 400)
        .task {
            model.load()
        }
    }

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
