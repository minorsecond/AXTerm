import SwiftUI

/// When first-run setup is shown by itself.
///
/// Once, on a station with no callsign, until it is finished or skipped.
/// Never in a unit-test host. A --test-mode instance starts with empty
/// settings, so it offers setup on every launch, which is how the operator
/// tries the flow; the test rig passes --callsign and never sees it. The
/// compose banner's button opens it whenever the callsign is missing,
/// skipped or not.
nonisolated enum FirstRunSetup {
    static let dismissedKey = "setup.firstRun.dismissed.v1"

    static func offersItself(callsign: String, dismissed: Bool, isTestInstance: Bool) -> Bool {
        !isTestInstance && !dismissed && StationCallsignRules.base(of: callsign).isEmpty
    }
}

/// Attaches first-run setup to a shell's main view: presented when the
/// router asks (`SettingsRouter.presentSetup`), and once by itself on a
/// station with no callsign.
struct FirstRunSetupHost: ViewModifier {
    @ObservedObject var router: SettingsRouter
    let settings: AppSettingsStore
    let winlinkSettings: WinlinkSettings
    let locationService: StationLocationService?
    let client: PacketEngine

    func body(content: Content) -> some View {
        // The sheet hangs off a background view of its own. Chained onto the
        // shell's view it shared a presentation slot with the inspector and
        // profile sheet, and SwiftUI showed only one of them, so "Set Up…"
        // did nothing.
        content.background {
            Color.clear
                .accessibilityHidden(true)
                .modifier(Presenter(router: router, settings: settings,
                                    winlinkSettings: winlinkSettings,
                                    locationService: locationService, client: client))
        }
    }

    private struct Presenter: ViewModifier {
        @ObservedObject var router: SettingsRouter
        let settings: AppSettingsStore
        let winlinkSettings: WinlinkSettings
        let locationService: StationLocationService?
        let client: PacketEngine

        func body(content: Content) -> some View {
            content
            .sheet(isPresented: $router.showsSetup) {
                FirstRunSetupView(settings: settings, winlinkSettings: winlinkSettings,
                                  locationService: locationService, client: client) { radio in
                    router.showsSetup = false
                    if let radio { router.navigate(to: .radioConnection, radio: radio) }
                }
                .environmentObject(router)
            }
            .task {
                let dismissed = settings.defaults.bool(forKey: FirstRunSetup.dismissedKey)
                if FirstRunSetup.offersItself(callsign: settings.myCallsign, dismissed: dismissed,
                                              isTestInstance: AppEnvironment.isUnitTestHost) {
                    router.presentSetup()
                }
            }
        }
    }
}

/// First-run setup: the station callsign, where the station is, and its radio.
///
/// Each step edits the same settings the Settings window does, through the
/// same views, so nothing here is a second home for anything. Skipping keeps
/// whatever has been entered so far.
struct FirstRunSetupView: View {
    @ObservedObject var settings: AppSettingsStore
    let winlinkSettings: WinlinkSettings
    let locationService: StationLocationService?
    let client: PacketEngine
    /// Called when setup closes, with the radio that was set up, if one was.
    let onClose: (RadioID?) -> Void

    enum Stage: Int, Equatable {
        case callsign
        case position
        case radio

        var index: Int { rawValue }
    }

    @State private var stage: Stage
    /// The Add Radio steps, shown in place of the radio stage while open.
    @State private var radioFlow: AddRadioFlow?
    /// Radios set up during this run of setup, marked in the list.
    @State private var configured: Set<RadioID> = []

    init(settings: AppSettingsStore, winlinkSettings: WinlinkSettings,
         locationService: StationLocationService?, client: PacketEngine,
         startingAt stage: Stage = .callsign, onClose: @escaping (RadioID?) -> Void) {
        self.settings = settings
        self.winlinkSettings = winlinkSettings
        self.locationService = locationService
        self.client = client
        self.onClose = onClose
        _stage = State(initialValue: stage)
    }

    var body: some View {
        Group {
            if let radioFlow {
                // Finishing or cancelling a radio comes back to the list, so
                // a station with several radios sets them all up here.
                AddRadioSheet(flow: radioFlow, client: client) { radio in
                    self.radioFlow = nil
                    if let radio { configured.insert(radio) }
                }
            } else {
                SetupFrame(title: "Set Up AXTerm", subtitle: stageSubtitle,
                           steps: ["Callsign", "Position", "Radio"], current: stage.index) {
                    stageContent
                } buttons: {
                    buttons
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var stageSubtitle: String {
        switch stage {
        case .callsign: return "Who this station is. Three short steps, and you can change any of it later."
        case .position: return "Where the station is. Distances, terrain profiles and position beacons are measured from here."
        case .radio: return "Set up each radio this station uses. You can add more later under Settings \u{203A} Radios."
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch stage {
        case .callsign:
            SetupCallsignStep(settings: settings)
        case .position:
            SetupPositionStep(settings: settings, winlinkSettings: winlinkSettings,
                              locationService: locationService)
        case .radio:
            radioStage
        }
    }

    @ViewBuilder
    private var radioStage: some View {
        let radios = settings.activeRadios
        SetupCard(title: radios.count == 1 ? "Radio" : "Radios (\(radios.count))",
                  note: "Each radio gets its own link, channel and SSID. A radio you don't set up "
                    + "now keeps its current settings.") {
            ForEach(Array(radios.enumerated()), id: \.element.id) { index, radio in
                if index > 0 { Divider() }
                radioRow(radio, canRemove: radios.count > 1)
            }
        }
        Button {
            radioFlow = AddRadioFlow(settings: settings, mode: .new)
        } label: {
            Label("Add a Radio\u{2026}", systemImage: "plus")
        }
        .controlSize(.large)
    }

    private func radioRow(_ radio: RadioProfile, canRemove: Bool) -> some View {
        let done = configured.contains(radio.id)
        return HStack(spacing: 12) {
            Image(systemName: Self.symbol(for: radio.kind))
                .font(.system(size: 18))
                .foregroundStyle(done ? Color.accentColor : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(RadioDetailView.title(for: radio))
                        .font(.callout.weight(.semibold))
                    if done {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Set up")
                    }
                }
                Text("\(Self.onAir(radio, station: settings.myCallsign))  \u{00B7}  "
                     + "\(RadioChannel.of(radio).title)  \u{00B7}  \(radio.displayEndpoint)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if done {
                Button("Edit\u{2026}") {
                    radioFlow = AddRadioFlow(settings: settings, mode: .configure(radio.id))
                }
            } else {
                Button("Set Up\u{2026}") {
                    radioFlow = AddRadioFlow(settings: settings, mode: .configure(radio.id))
                }
                .buttonStyle(.borderedProminent)
            }
            if canRemove {
                Button {
                    configured.remove(radio.id)
                    settings.archiveRadio(radio.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this radio")
                .accessibilityLabel("Remove \(RadioDetailView.title(for: radio))")
            }
        }
    }

    private static func symbol(for kind: RadioTransportKind) -> String {
        switch kind {
        case .ble: return "dot.radiowaves.left.and.right"
        case .serial: return "cable.connector"
        case .tcp: return "network"
        case .modem: return "waveform"
        }
    }

    private static func onAir(_ radio: RadioProfile, station: String) -> String {
        let call = radio.resolvedCallsign(station: station)
        return call.isEmpty ? "\u{2014}" : call
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Skip Setup") { finish(radio: nil) }
            .keyboardShortcut(.cancelAction)
        Spacer()
        if stage != .callsign {
            Button("Back") { stage = stage == .radio ? .position : .callsign }
        }
        switch stage {
        case .callsign:
            Button("Continue") { stage = .position }
                .keyboardShortcut(.defaultAction)
                .disabled(!CallsignValidator.isValidCallsign(settings.myCallsign))
        case .position:
            Button("Continue") { stage = .radio }
                .keyboardShortcut(.defaultAction)
        case .radio:
            Button("Done") { finish(radio: nil) }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Setup is over, finished or skipped: it does not offer itself again.
    private func finish(radio: RadioID?) {
        settings.defaults.set(true, forKey: FirstRunSetup.dismissedKey)
        onClose(radio)
    }
}
