import SwiftUI

/// The Connection pane on a Mac — and, once there is more than one radio,
/// the Radios pane.
///
/// With one radio this is that radio's form and nothing else: no list, no
/// back button, no name to edit, exactly the Connection pane the app has
/// always had, plus one quiet row at the bottom for adding a second radio.
/// Nothing says "radios" until the operator has two. From then on it is a
/// list with a form pushed over it, and a deep link that names a radio — the
/// toolbar capsule's "TNC Settings…", the Link Layer page's "Open Radio
/// Settings…" — lands on that form with the list beneath it for the back
/// button, which is where those links have always landed.
struct RadiosSettingsView: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    @EnvironmentObject private var router: SettingsRouter
    @State private var path: [RadioID] = []

    var body: some View {
        if settings.hasMultipleRadios {
            NavigationStack(path: $path) {
                RadiosListView(settings: settings, client: client,
                               destination: { $0 },
                               onAdd: { path = [$0] })
                    .navigationDestination(for: RadioID.self) { id in
                        RadioDetailView(radioID: id, settings: settings, client: client)
                    }
            }
            .onAppear(perform: honourDeepLink)
            .onChange(of: router.pendingRadio) { _, _ in honourDeepLink() }
        } else if let only = settings.activeRadios.first {
            RadioDetailView(radioID: only.id, settings: settings, client: client,
                            onAddSecondRadio: { path = [settings.addRadio().id] })
                .id(only.id)
                .onAppear { router.pendingRadio = nil }
        }
    }

    private func honourDeepLink() {
        guard let radio = router.pendingRadio else { return }
        router.pendingRadio = nil
        if settings.radio(radio) != nil { path = [radio] }
    }
}

/// One row per radio. Generic over the navigation value so the Mac pane can
/// push a `RadioID` while the iOS shell pushes its own destination enum
/// through the stack it already owns.
struct RadiosListView<Destination: Hashable>: View {
    @ObservedObject var settings: AppSettingsStore
    @ObservedObject var client: PacketEngine
    let destination: (RadioID) -> Destination
    let onAdd: (RadioID) -> Void

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
                    // Stated rather than discovered: until the link layer can
                    // hold more than one radio, this is exactly what happens.
                    if settings.hasMultipleRadios {
                        Text("AXTerm connects to the first enabled radio. Drag to reorder.")
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
                    onAdd(settings.addRadio().id)
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
        return call.isEmpty ? radio.displayEndpoint : "\(call) \u{b7} \(radio.displayEndpoint)"
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

/// One radio's form: how its TNC is reached and the link as it stands — and,
/// once there are several radios, what it is called and whether it is on.
///
/// Only controls the code acts on. The per-radio callsign, KISS port and
/// auto-connect exist in the profile and arrive here with the phases that
/// give them effect — a switch that changes nothing teaches the operator to
/// stop trusting switches.
struct RadioDetailView: View {
    let radioID: RadioID
    @ObservedObject var settings: AppSettingsStore
    @StateObject private var viewModel: ConnectionTransportViewModel
    /// Supplied by the single-radio pane: the one door to a second radio.
    var onAddSecondRadio: (() -> Void)?

    init(radioID: RadioID, settings: AppSettingsStore, client: PacketEngine,
         onAddSecondRadio: (() -> Void)? = nil) {
        self.radioID = radioID
        self.settings = settings
        self.onAddSecondRadio = onAddSecondRadio
        _viewModel = StateObject(wrappedValue: ConnectionTransportViewModel(
            radioID: radioID, settings: settings, packetEngine: client))
    }

    var body: some View {
        let transportBinding = Binding<TransportSelection>(
            get: { viewModel.selectedTransport },
            set: { viewModel.userDidChangeTransport($0) }
        )

        Form {
            // A name and a switch only mean something against other radios.
            if settings.hasMultipleRadios {
                Section {
                    TextField("Name", text: $viewModel.name, prompt: Text(RadioProfile.defaultName(for: profile)))
                    Toggle("Enabled", isOn: $viewModel.enabled)
                } header: {
                    Text("Radio")
                } footer: {
                    Text(viewModel.enabled
                         ? "The first enabled radio in the list is the one AXTerm connects to."
                         : "Off: kept in the list, not connected.")
                }
            }

            // With one radio its callsign is the station callsign, set under
            // General; a second field saying the same thing would be noise.
            if settings.hasMultipleRadios {
                Section {
                    CallsignField(title: stationCallsign.isEmpty ? "NOCALL" : stationCallsign,
                                  text: $viewModel.callsign)
                } header: {
                    Text("Identity")
                } footer: {
                    Text("Leave empty to operate as \(stationCallsign.isEmpty ? "your station callsign" : stationCallsign). "
                         + "Give this radio its own SSID when two radios share a frequency, or when a "
                         + "remote station should be able to reach this radio in particular. A call to "
                         + "an SSID only one radio uses is answered by that radio whichever link heard it.")
                }
            }

            Section {
                Picker("Transport", selection: transportBinding) {
                    ForEach(TransportSelection.selectable(including: viewModel.selectedTransport)) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch viewModel.selectedTransport {
                case .network:
                    NetworkSettingsContent(viewModel: viewModel)
                case .serial:
                    SerialSettingsContent(viewModel: viewModel)
                case .ble:
                    BLESettingsContent(viewModel: viewModel)
                case .modem:
                    ModemSettingsContent(viewModel: viewModel)
                }
            } header: {
                Text("Transport")
            }

            #if os(macOS)
            if viewModel.selectedTransport == .modem {
                ModemRigSection(viewModel: viewModel)
                ModemTransmitSection(viewModel: viewModel)
                ModemRadioSection(viewModel: viewModel)
            }
            #endif

            Section {
                ConnectionStatusView(status: viewModel.connectionStatus)

                if viewModel.selectedTransport == .modem, viewModel.connectionStatus == .connected {
                    ModemStatusRows(viewModel: viewModel)
                }

                // What is on the other end of the link. Direwolf answers the
                // in-band KISS hardware query with its name and version; a
                // silent TNC is plain KISS, which is itself the answer.
                if viewModel.connectionStatus == .connected,
                   viewModel.selectedTransport == .network || viewModel.selectedTransport == .modem {
                    if let identity = viewModel.tncIdentity {
                        LabeledContent {
                            HStack(spacing: 6) {
                                Text(identity)
                                    .font(.system(.body, design: .monospaced))
                                if TNCIdentifier.isDirewolf(identity) {
                                    Text("Direwolf")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.green.opacity(0.2)))
                                        .foregroundStyle(.green)
                                }
                            }
                        } label: {
                            Text("Software")
                        }
                        .help("The TNC named itself over the KISS hardware "
                              + "query — asked and answered on this TCP link, "
                              + "nothing transmitted on the air.")
                    } else {
                        LabeledContent {
                            Button("Ask") { viewModel.identifyTNC() }
                                .controlSize(.small)
                        } label: {
                            Text("Software")
                            Text("Has not identified itself — plain KISS, "
                                 + "or the query went unanswered.")
                        }
                        .help("Sends the KISS SetHardware \u{201C}TNC:\u{201D} query. "
                              + "Direwolf answers with its version; hardware "
                              + "TNCs that don't implement the extension "
                              + "ignore it. Nothing is transmitted on RF.")
                    }
                }

                if viewModel.isPrimary {
                    Button {
                        if viewModel.canConnect {
                            viewModel.connect()
                        } else {
                            viewModel.disconnect()
                        }
                    } label: {
                        if viewModel.connectionStatus == .connecting {
                            Label("Connecting\u{2026}", systemImage: "hourglass")
                        } else if viewModel.canConnect {
                            Label("Connect", systemImage: "bolt.horizontal.circle")
                        } else {
                            Label("Disconnect", systemImage: "bolt.horizontal.circle.fill")
                        }
                    }
                    .disabled(viewModel.connectionStatus == .connecting)
                } else {
                    Text("Not the first enabled radio, so not connected. Move it up, or switch the one above it off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.hasMultipleRadios {
                Section {
                    Toggle("Send beacons", isOn: serviceBinding(\.sendsBeacons))
                    Toggle("Ping stations", isOn: serviceBinding(\.pings))
                    Toggle("Announce the NET/ROM node", isOn: serviceBinding(\.announcesNode))
                    Toggle("Answer mailbox calls", isOn: serviceBinding(\.answersMailbox))
                } header: {
                    Text("Services on this radio")
                } footer: {
                    Text("Every service runs on every radio unless switched off here. Whether a "
                         + "service runs at all is set under Transmission and BBS; these rows only "
                         + "say which radios it uses.")
                }
            }

            if settings.hasMultipleRadios {
                Section {
                    Button("Remove Radio", role: .destructive) {
                        settings.archiveRadio(radioID)
                        dismiss()
                    }
                }
            } else if let onAddSecondRadio {
                // The one place a second radio can come from. Quiet, at the
                // bottom, and the only thing on this form that is new.
                Section {
                    Button {
                        onAddSecondRadio()
                    } label: {
                        Label("Add a second radio\u{2026}", systemImage: "plus")
                    }
                } footer: {
                    Text("Another TNC — a second Direwolf, a portable rig, a station reached over the network. Each radio has its own connection.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(settings.hasMultipleRadios
                         ? (viewModel.name.isEmpty ? RadioProfile.defaultName(for: profile) : viewModel.name)
                         : "Connection")
        .onAppear {
            viewModel.onAppear()
            viewModel.suspendAutoReconnect(true)
        }
        .onDisappear {
            viewModel.onDisappear()
            viewModel.suspendAutoReconnect(false)
        }
    }

    @Environment(\.dismiss) private var dismiss

    private var profile: RadioProfile {
        settings.radio(radioID) ?? RadioProfile(id: radioID, name: "")
    }

    private var stationCallsign: String { settings.myCallsign.uppercased() }

    private func serviceBinding(_ keyPath: WritableKeyPath<RadioProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.radio(radioID)?[keyPath: keyPath] ?? true },
            set: { value in
                settings.updateRadio(radioID) { $0[keyPath: keyPath] = value }
                // The node's L2 aliases are registered when configured, not
                // when announced.
                SessionCoordinator.shared?.applyNetRomNodeSettings(settings)
            })
    }
}
