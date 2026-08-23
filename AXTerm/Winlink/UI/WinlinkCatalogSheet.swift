import SwiftUI

/// Winlink catalog browser: pick data products (weather, bulletins…),
/// queue a request message, receive the products as mail later.
struct WinlinkCatalogSheet: View {

    enum Source: String, CaseIterable {
        case catalog = "Winlink Catalog"
        case sailDocs = "Internet (SailDocs)"
    }

    @ObservedObject var viewModel: WinlinkCatalogViewModel
    let myCallsign: String
    var locationService: StationLocationService?
    var onQueued: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var queuedConfirmation = false
    @State private var source: Source = .catalog
    @State private var sailDocsURL = ""
    @State private var sailDocsCustom = ""
    @State private var isFetchingSpot = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                .labelsHidden()
                .help(source == .catalog ? WinlinkCopy.catalogTooltip
                      : "SailDocs is a free email robot reachable through the Winlink internet gateway — it mails back web pages, forecasts, and weather data. The unofficial way to pull internet data over packet radio.")
                Spacer()
                if let fetchedAt = viewModel.fetchedAt {
                    Text("Updated \(fetchedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    if viewModel.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isRefreshing)
                .help(WinlinkCopy.catalogRefreshTooltip)
            }
            .padding(12)
            Divider()

            if source == .sailDocs {
                sailDocsPane
            } else {

            if let error = viewModel.errorText {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            if viewModel.groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No catalog cached yet")
                        .font(.headline)
                    Text("The catalog web service needs a personal access key, but every station can request the catalog **over the air**: queue a LIST inquiry, send it with Connect & Exchange, and the index arrives as mail.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button {
                        if viewModel.queueCatalogListRequest(myCallsign: myCallsign) != nil {
                            queuedConfirmation = true
                            onQueued()
                        }
                    } label: {
                        Label("Request Catalog by Radio", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .help("Queues a LIST inquiry to INQUIRY in your Outbox — no internet or access key needed.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.groups) { group in
                        Section(group.category) {
                            ForEach(group.items, id: \.inquiryId) { item in
                                row(for: item)
                            }
                        }
                    }
                }
            }

            }

            Divider()
            HStack {
                if !viewModel.selection.isEmpty {
                    Text("\(viewModel.selection.count) selected · ≈\(ByteCountFormatter.string(fromByteCount: Int64(viewModel.selectedSizeEstimate), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(WinlinkCopy.catalogSizeTooltip)
                }
                Spacer()
                Button("Close") { dismiss() }
                if source == .catalog {
                    Button("Request \(viewModel.selection.count) Item\(viewModel.selection.count == 1 ? "" : "s")") {
                        if viewModel.queueRequest(myCallsign: myCallsign) != nil {
                            queuedConfirmation = true
                            onQueued()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.selection.isEmpty)
                    .help("Queues a request message to INQUIRY in your Outbox. Send it with Connect & Exchange; the data arrives as mail at a later exchange.")
                }
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 460)
        .alert("Request queued", isPresented: $queuedConfirmation) {
            Button("OK") { dismiss() }
        } message: {
            Text("The catalog request is in your Outbox. Run Connect & Exchange to send it; the response arrives as ordinary mail on a later exchange.")
        }
    }

    // MARK: - SailDocs

    private var sailDocsPane: some View {
        Form {
            Section {
                Text("SailDocs (saildocs.com) answers email commands with web pages, forecasts, and weather data — through the Winlink internet gateway, that means over the radio. Requests queue in your Outbox; replies arrive as mail at a later exchange. Keep responses small: 10 kB is roughly two minutes of airtime at 1200 baud.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Fetch a web page as text") {
                HStack {
                    TextField("URL", text: $sailDocsURL, prompt: Text("https://forecast.weather.gov/…"))
                        .textFieldStyle(.roundedBorder)
                    Button("Queue") {
                        queueSailDocs([.webPage(url: sailDocsURL)])
                        sailDocsURL = ""
                    }
                    .disabled(sailDocsURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .help("SailDocs strips the page to plain text before mailing it back — 'send <url>'.")
            }

            if locationService != nil {
                Section("Weather for my position") {
                    Button {
                        isFetchingSpot = true
                        Task { @MainActor in
                            defer { isFetchingSpot = false }
                            guard let location = await locationService?.currentLocation() else { return }
                            queueSailDocs([.spotForecast(
                                latitude: location.latitude, longitude: location.longitude)])
                        }
                    } label: {
                        if isFetchingSpot {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Queue spot forecast for my position", systemImage: "location")
                        }
                    }
                    .disabled(isFetchingSpot)
                    .help("Requests a SailDocs text spot forecast ('send spot:lat,lon') for your current position — GPS when available, otherwise your grid square.")
                }
            }

            Section("Custom command") {
                HStack {
                    TextField("Command", text: $sailDocsCustom, prompt: Text("e.g. send gfs:38N,42N,102W,108W"))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Button("Queue") {
                        queueSailDocs([.custom(sailDocsCustom)])
                        sailDocsCustom = ""
                    }
                    .disabled(sailDocsCustom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .help("Any SailDocs command line (see saildocs.com for the full list). GRIB requests return binary attachments — mind the airtime.")
            }
        }
        .formStyle(.grouped)
    }

    private func queueSailDocs(_ requests: [SailDocsRequestBuilder.Request]) {
        if viewModel.queueSailDocsRequest(requests, myCallsign: myCallsign) != nil {
            queuedConfirmation = true
            onQueued()
        }
    }

    private func row(for item: WinlinkCatalogItemRecord) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { viewModel.selection.contains(item.inquiryId) },
                set: { selected in
                    if selected {
                        viewModel.selection.insert(item.inquiryId)
                    } else {
                        viewModel.selection.remove(item.inquiryId)
                    }
                })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.subject.isEmpty ? item.inquiryId : item.subject)
                    Text(item.inquiryId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.sizeEstimate), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(WinlinkCopy.catalogSizeTooltip)
        }
    }
}
