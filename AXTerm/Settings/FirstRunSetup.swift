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
                AddRadioSheet(flow: radioFlow, client: client) { radio in
                    self.radioFlow = nil
                    if let radio { finish(radio: radio) }
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
        case .position: return "Where the station is. The map, distances, terrain and APRS beacons start here."
        case .radio: return "How AXTerm reaches your radio, what its channel is for, and its SSID."
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
        SetupCard(title: radios.count == 1 ? "Your radio" : "Your radios",
                  note: radios.count == 1
                    ? "Set it up to choose how it is reached, its channel and its SSID. You can "
                        + "also leave it and change it later under Settings \u{203A} Radios."
                    : "Your radios are set up already. Each has its own page under Settings \u{203A} Radios.") {
            ForEach(Array(radios.enumerated()), id: \.element.id) { index, radio in
                if index > 0 { Divider() }
                HStack(alignment: .firstTextBaseline) {
                    SetupReadout(rows: [
                        ("Radio", RadioDetailView.title(for: radio)),
                        ("Reached by", radio.displayEndpoint),
                        ("Channel", RadioChannel.of(radio).title),
                        ("On air as", Self.onAir(radio, station: settings.myCallsign)),
                    ])
                    Spacer(minLength: 0)
                }
            }
        }
        HStack(spacing: 10) {
            if radios.count == 1, let only = radios.first {
                Button {
                    radioFlow = AddRadioFlow(settings: settings, mode: .configure(only.id))
                } label: {
                    Label("Set Up This Radio\u{2026}", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                radioFlow = AddRadioFlow(settings: settings, mode: .new)
            } label: {
                Label(radios.count == 1 ? "Add Another Radio\u{2026}" : "Add a Radio\u{2026}",
                      systemImage: "plus")
            }
        }
        .controlSize(.large)
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
