import SwiftUI

/// The Radios pane on a Mac: always the list, with each radio's page pushed
/// over it.
///
/// With one radio the pane opens straight onto that radio's page, which is
/// the same page a second radio gets, titled with the radio's name; the back
/// button leads to the list and its Add Radio button. A deep link that names
/// a radio (the toolbar capsule's "TNC Settings…", a sidebar radio's "Radio
/// Settings…") lands on that radio's page with the list beneath it.
struct RadiosSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    @EnvironmentObject private var router: SettingsRouter
    @State private var path: [RadioID] = []
    /// Set once the pane has opened the only radio by itself, so going back
    /// to the list is not undone a moment later.
    @State private var openedOnlyRadio = false
    /// The Add Radio sheet's state while it is open. Made in the button's
    /// action, because making it adds the radio.
    @State private var addFlow: AddRadioFlow?

    var body: some View {
        NavigationStack(path: $path) {
            RadiosListView(settings: settings, client: client,
                           destination: { $0 },
                           onAdd: { addFlow = AddRadioFlow(settings: settings, mode: .new) })
                .navigationDestination(for: RadioID.self) { id in
                    RadioDetailView(radioID: id, settings: settings, client: client)
                }
        }
        .onAppear(perform: arrive)
        .onChange(of: router.pendingRadio) { _, _ in honourDeepLink() }
        .sheet(item: $addFlow) { flow in
            AddRadioSheet(flow: flow, client: client) { added in
                addFlow = nil
                if let added { path = [added] }
            }
        }
    }

    private func arrive() {
        if router.pendingRadio != nil {
            honourDeepLink()
        } else if !openedOnlyRadio, !settings.hasMultipleRadios, let only = settings.activeRadios.first {
            openedOnlyRadio = true
            path = [only.id]
        }
    }

    /// Open the radio a deep link names, or the only radio when it names none.
    private func honourDeepLink() {
        guard let radio = router.pendingRadio else { return }
        DispatchQueue.main.async {
            router.pendingRadio = nil
            if settings.radio(radio) != nil { path = [radio] }
        }
    }
}

/// One row per radio. Generic over the navigation value so the Mac pane can
/// push a `RadioID` while the iOS shell pushes its own destination enum
/// through the stack it already owns.
struct RadiosListView<Destination: Hashable>: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    let destination: (RadioID) -> Destination
    /// Opens the Add Radio sheet. The sheet adds the radio, and takes it
    /// away again if the operator cancels.
    let onAdd: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(settings.activeRadios) { radio in
                    NavigationLink(value: destination(radio.id)) {
                        RadioListRow(radio: radio,
                                     status: status(for: radio),
                                     stationCallsign: settings.myCallsign)
                    }
                }
                .onMove { settings.moveRadios(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Radios")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.hasMultipleRadios {
                        Text("Every enabled radio connects. The first leads where one radio has to "
                             + "stand for the station. Drag to reorder.")
                    }
                    ForEach(issueLines, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }

            Section {
                Button {
                    onAdd()
                } label: {
                    Label("Add Radio\u{2026}", systemImage: "plus")
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #else
        .listStyle(.insetGrouped)
        #endif
    }

    /// The engine holds one link, and it is the primary radio's.
    private func status(for radio: RadioProfile) -> ConnectionStatus {
        radio.id == settings.primaryRadio?.id ? client.status : .disconnected
    }

    private var issueLines: [String] {
        RadioProfileIssue.issues(in: settings.radios, stationCallsign: settings.myCallsign).map { issue in
            switch issue {
            case let .duplicateLink(a, b):
                return "\(name(a)) and \(name(b)) use the same TNC and port; only one can hold it."
            case let .duplicateCallsign(a, b, call):
                return "\(name(a)) and \(name(b)) both answer as \(call). Fine on different frequencies, a collision on the same one."
            case let .duplicateAudioDevice(a, b):
                return "\(name(a)) and \(name(b)) share an audio device; a sound device can serve one modem."
            case let .duplicateSerialPort(a, b):
                return "\(name(a)) and \(name(b)) use the same serial port; only one can open it."
            }
        }
    }

    private func name(_ id: RadioID) -> String {
        settings.radio(id)?.name ?? "A radio"
    }
}

private struct RadioListRow: View {
    let radio: RadioProfile
    let status: ConnectionStatus
    let stationCallsign: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .help(RadioPresentation.dotHelp(summary))
            VStack(alignment: .leading, spacing: 2) {
                Text(radio.name.isEmpty ? radio.displayEndpoint : radio.name)
                    .foregroundStyle(radio.enabled ? .primary : .secondary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !radio.enabled {
                Text("Off")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let call = radio.resolvedCallsign(station: stationCallsign)
        let parts = [RadioChannel.of(radio).title, call, radio.displayEndpoint].filter { !$0.isEmpty }
        return parts.joined(separator: " \u{b7} ")
    }

    private var summary: RadioStatusSummary {
        RadioStatusSummary(id: radio.id, name: radio.name,
                           callsign: radio.resolvedCallsign(station: stationCallsign),
                           status: status, endpoint: radio.displayEndpoint,
                           host: radio.kind == .tcp ? radio.host : "",
                           port: radio.kind == .tcp ? radio.port : nil,
                           lastError: nil, lastRx: nil, lastTx: nil)
    }

    private var tint: Color {
        switch RadioPresentation.tint(for: status) {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: Color(platform: .platformTertiaryLabel)
        }
    }
}

