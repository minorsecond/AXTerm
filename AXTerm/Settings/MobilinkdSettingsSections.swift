//
//  MobilinkdSettingsSections.swift
//  AXTerm
//
//  The TNC4 part of a radio's settings: what the TNC4 reports, the settings
//  this radio applies to it, audio measurement and test tones, and saving to
//  the TNC4 itself. See Docs/MobilinkdTNC4.md.
//

import Combine
import SwiftUI

struct MobilinkdSettingsSections: View {
    let radioID: RadioID
    @ObservedObject var client: PacketEngine
    @ObservedObject var viewModel: ConnectionTransportViewModel
    /// The radio is on an APRS channel, where calibration may send a beacon.
    var onAPRS = false
    /// Opens the TNC4 tuning wizard.
    var openTuning: (() -> Void)?

    @State private var tone: MobilinkdTestTone = .both
    @State private var confirmingTone = false
    @State private var toneEndsAt: Date?
    @State private var measuring = false
    @State private var confirmingSave = false
    @State private var confirmingAssistant = false
    @StateObject private var assistant = MobilinkdLevelAssistantRunner()

    private var device: MobilinkdDeviceState { client.mobilinkdDevices[radioID] ?? MobilinkdDeviceState() }
    private var control: MobilinkdControlling? { client.mobilinkdControl(for: radioID) }
    private var connected: Bool { viewModel.radioConnected && control != nil }

    /// A Bluetooth LE radio shows these once its TNC has identified itself as
    /// a Mobilinkd (or the profile already manages TNC4 settings); a serial
    /// radio when the operator has said it is one.
    private var applies: Bool {
        switch viewModel.selectedTransport {
        case .ble:
            return device.firmwareVersion != nil || control != nil || !viewModel.tnc4.isEmpty
        case .serial:
            return viewModel.mobilinkdEnabled
        default:
            return false
        }
    }

    var body: some View {
        Group {
            if applies {
                statusSection
                receiveSection
                transmitSection
                interfaceSection
                saveSection
            }
        }
        // The TNC4 is read from the radio form (RadioDetailView), which is
        // always on screen; see readTNC4WhenUp.
        .onDisappear {
            assistant.cancel()
            control?.stopMeasuringInput()
            control?.stopTestTone()
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            if connected {
                LabeledContent("Model", value: device.hardwareVersion ?? "—")
                LabeledContent("Firmware", value: device.firmwareVersion ?? "—")
                if let serial = device.serialNumber { LabeledContent("Serial number", value: serial) }
                if let mV = device.batteryMillivolts, let fraction = device.batteryFraction {
                    LabeledContent("Battery") {
                        HStack(spacing: 8) {
                            ProgressView(value: fraction)
                                .tint(fraction < 0.15 ? .red : fraction < 0.33 ? .orange : .green)
                                .frame(width: 80)
                            Text(String(format: "%.2f V", Double(mV) / 1000))
                                .monospacedDigit()
                        }
                    }
                }
                Button("Read the TNC4 again") { control?.refreshMobilinkdStatus() }
                    .disabled(control?.mobilinkdActivity != .idle)
            } else {
                Text("Connect this radio to read and adjust the TNC4. The settings below are kept either way and applied when it connects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Mobilinkd TNC4")
        } footer: {
            Text("Settings you set here apply to this radio only. AXTerm sends them when the radio connects and puts the TNC4's own back when it disconnects, so another radio using the same TNC4 isn't affected. Nothing is saved to the TNC4 unless you use Save below.")
        }
    }

    // MARK: Receive

    private var receiveSection: some View {
        Section {
            if connected, let openTuning {
                LabeledContent {
                    Button("Tune This TNC4\u{2026}") { openTuning() }
                        .disabled(measuring || toneEndsAt != nil || assistant.running)
                } label: {
                    Text("Tuning")
                    Text("Steps through the receive gain and a check on real packets.")
                }
            }
            levelMeter
            ReceiveLevelTuningRows(radioID: radioID, onAPRS: onAPRS, connected: connected,
                                   blocked: measuring || toneEndsAt != nil || assistant.running,
                                   monitor: client.receiveLevel)
            if connected { levelAssistant }
            ManagedTNC4Setting(title: "Input gain for this radio", value: $viewModel.tnc4.inputGain,
                               tncValue: device.inputGain, fallback: 0, describe: Self.gainText) { binding in
                Picker("Input gain", selection: binding) {
                    ForEach((device.minInputGain ?? 0)...(device.maxInputGain ?? 4), id: \.self) {
                        Text(Self.gainText($0)).tag($0)
                    }
                }
            }
            ManagedTNC4Setting(title: "Input twist for this radio", value: $viewModel.tnc4.inputTwist,
                               tncValue: device.inputTwist, fallback: 0, describe: { "\($0) dB" }) { binding in
                Picker("Input twist", selection: binding) {
                    ForEach((device.minInputTwist ?? -3)...(device.maxInputTwist ?? 9), id: \.self) {
                        Text("\($0) dB").tag($0)
                    }
                }
            }
        } header: {
            Text("Receive audio")
        } footer: {
            Text("Calibrating measures real packets, which is the level that matters. The meter and \u{201C}Find the right gain\u{201D} measure noise: use them with the radio's squelch open on a quiet channel, and aim for a level that never touches either end. For the same level, less gain and more radio volume recovers faster after transmitting. Twist is usually 6 dB for a radio's speaker output and 0 dB for flat audio.")
        }
        .id(SettingsSection.radioReceiveAudio)
    }

    @ViewBuilder
    private var levelMeter: some View {
        if connected {
            let level = measuring ? device.inputLevel : nil
            LabeledContent("Level") {
                HStack(spacing: 8) {
                    if let level {
                        let fraction = level.fraction
                        let clipped = level.clipped
                        ProgressView(value: fraction)
                            .tint(clipped ? .red : fraction < 0.1 ? .orange : .green)
                            .frame(width: 120)
                        Text(clipped ? "Clipping" : "\(Int(fraction * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(clipped ? .red : .primary)
                    }
                    Button(measuring ? "Stop" : "Measure") {
                        if measuring { control?.stopMeasuringInput() } else { control?.startMeasuringInput() }
                        measuring.toggle()
                    }
                    .disabled(toneEndsAt != nil)
                }
            }
            if measuring {
                Text("Packets aren't received while measuring. Stops on its own after two minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var levelAssistant: some View {
        LabeledContent("Input gain") {
            if assistant.running {
                HStack {
                    Text(assistant.status ?? "").foregroundStyle(.secondary)
                    Button("Cancel") { assistant.cancel() }
                }
            } else {
                Button("Find the right gain\u{2026}") { confirmingAssistant = true }
                    .disabled(measuring || toneEndsAt != nil)
            }
        }
        .confirmationDialog("Find the right input gain?", isPresented: $confirmingAssistant) {
            Button("Start") {
                guard let control else { return }
                let id = radioID
                assistant.run(control: control,
                              gains: (device.minInputGain ?? 0)...(device.maxInputGain ?? 4),
                              reading: { [client] in
                                  let d = client.mobilinkdDevices[id]
                                  return (d?.inputLevel, d?.inputLevelAt)
                              },
                              setGain: { [viewModel] in viewModel.tnc4.inputGain = $0 })
            }
        } message: {
            Text("Open the radio's squelch on a quiet channel first. AXTerm tries each input gain from the lowest up and keeps the lowest one that gives a clean level. It takes about half a minute, and packets aren't received meanwhile.")
        }
        if let message = assistant.resultMessage {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Transmit

    private var transmitSection: some View {
        Section {
            ManagedTNC4Setting(title: "Output level for this radio", value: $viewModel.tnc4.outputGain,
                               tncValue: device.outputGain, fallback: 63, describe: { "\($0)" }) { binding in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Slider(value: Self.double(binding), in: 0...255, step: 1)
                        Text("\(binding.wrappedValue)").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                    if binding.wrappedValue > 64 {
                        Label("Mobilinkd advises no more than 64 for a handheld: its mic input is built for very low levels.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            ManagedTNC4Setting(title: "Output twist for this radio", value: $viewModel.tnc4.outputTwist,
                               tncValue: device.outputTwist, fallback: 50, describe: { "\($0)" }) { binding in
                HStack {
                    Slider(value: Self.double(binding), in: 0...100, step: 1)
                    Text("\(binding.wrappedValue)").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
            if connected { testTone }
        } header: {
            Text("Transmit audio")
        } footer: {
            Text("Output twist 50 is flat; lower cuts 2200 Hz, higher cuts 1200 Hz. A test tone lets you set the level while listening on another receiver; the output level can be changed while it plays.")
        }
    }

    @ViewBuilder
    private var testTone: some View {
        LabeledContent("Test tone") {
            HStack {
                Picker("Tone", selection: $tone) {
                    ForEach(MobilinkdTestTone.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(toneEndsAt != nil)
                if let ends = toneEndsAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(ends.timeIntervalSince(context.date).rounded(.up)))
                        Text("On the air, \(left) s").monospacedDigit().foregroundStyle(.red)
                            .onChange(of: left) { _, now in if now == 0 { toneEndsAt = nil } }
                    }
                    Button("Stop") { control?.stopTestTone(); toneEndsAt = nil }
                } else {
                    Button("Send\u{2026}") { confirmingTone = true }
                }
            }
        }
        .confirmationDialog("Key the radio?", isPresented: $confirmingTone) {
            Button("Send \(tone.title) for \(Int(MobilinkdTNC.defaultToneSeconds)) seconds") {
                if measuring { measuring = false }
                control?.startTestTone(tone, for: MobilinkdTNC.defaultToneSeconds)
                toneEndsAt = Date().addingTimeInterval(MobilinkdTNC.defaultToneSeconds)
            }
        } message: {
            Text("The radio transmits a steady tone until you stop it or \(Int(MobilinkdTNC.defaultToneSeconds)) seconds pass. Make sure it's on a frequency where that's OK, ideally into a dummy load.")
        }
    }

    // MARK: Interface

    private var interfaceSection: some View {
        Section {
            ManagedTNC4Setting(title: "PTT style for this radio", value: $viewModel.tnc4.pttMultiplex,
                               tncValue: device.pttMultiplex, fallback: true,
                               describe: { $0 ? "Multiplex" : "Simplex" }) { binding in
                Picker("PTT style", selection: binding) {
                    Text("Multiplex (PTT on the mic line)").tag(true)
                    Text("Simplex (separate PTT line)").tag(false)
                }
            }
            ManagedTNC4Setting(title: "Modem for this radio", value: $viewModel.tnc4.modemType,
                               tncValue: device.modemType.map(Int.init), fallback: 1,
                               describe: Self.modemText) { binding in
                Picker("Modem", selection: binding) {
                    ForEach(device.supportedModemTypes?.map(Int.init) ?? [1, 3, 5], id: \.self) {
                        Text(Self.modemText($0)).tag($0)
                    }
                }
            }
        } header: {
            Text("Radio interface")
        } footer: {
            Text("Most handhelds use multiplex PTT. TX delay and the rest of the timing are under Timing, further down this page.")
        }
    }

    // MARK: Save

    private var saveSection: some View {
        Section {
            Button("Make these the TNC4's own settings\u{2026}") { confirmingSave = true }
                .disabled(!connected || !device.canSave)
            if let saved = device.lastSavedAt {
                Text("Saved to the TNC4 \(saved.formatted(.relative(presentation: .named))).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Writes what the TNC4 is using now into its memory. Normally you don't need this: AXTerm applies this radio's settings on every connect.")
        }
        .confirmationDialog("Save to the TNC4?", isPresented: $confirmingSave) {
            Button("Save to the TNC4") { control?.saveSettingsToTNC() }
        } message: {
            Text("The TNC4 will start with these settings from now on, with every radio it's plugged into, including ones you use without AXTerm. Other radios in AXTerm that have their own TNC4 settings still get theirs when they connect.")
        }
    }

    // MARK: Formatting

    static func gainText(_ step: Int) -> String { step == 0 ? "0 dB" : "+\(step * 6) dB" }

    static func modemText(_ type: Int) -> String {
        switch type {
        case 1: return "1200 baud AFSK"
        case 2: return "300 baud AFSK"
        case 3: return "9600 baud"
        case 4: return "PSK31"
        case 5: return "M17"
        default: return "Type \(type)"
        }
    }

    private static func double(_ binding: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) })
    }
}

/// One TNC4 setting a radio can either set or leave to the TNC4.
private struct ManagedTNC4Setting<Value: Hashable, Control: View>: View {
    let title: String
    @Binding var value: Value?
    /// What the TNC4 reports, when known.
    let tncValue: Value?
    /// Where the control starts when switched on and the TNC4 hasn't said.
    let fallback: Value
    let describe: (Value) -> String
    @ViewBuilder let control: (Binding<Value>) -> Control

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { value != nil },
            set: { value = $0 ? (tncValue ?? fallback) : nil }))
            // Named outright: in the grouped form VoiceOver found these
            // switches with no title at all.
            .accessibilityLabel(title)
        if value != nil {
            control(Binding(get: { value ?? fallback }, set: { value = $0 }))
        } else {
            Text("Using the TNC4's own: \(tncValue.map(describe) ?? "not read yet")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Runs `MobilinkdLevelAssistant` against a connected TNC4.
@MainActor
final class MobilinkdLevelAssistantRunner: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status: String?
    @Published private(set) var resultMessage: String?
    /// Where the last run ended. Nil while running, after a cancel, and when
    /// the TNC4 sent no levels.
    @Published private(set) var outcome: MobilinkdLevelAssistant.Step?
    private var task: Task<Void, Never>?
    private weak var control: MobilinkdControlling?

    /// The TNC4 re-centers its input for about a second after a gain change
    /// (tnc4-firmware AudioLevel.cpp, setAudioInputLevels).
    static let settleSeconds = 2.5
    static let sampleSeconds = 2.0

    func run(control: MobilinkdControlling, gains: ClosedRange<Int>,
             reading: @escaping () -> (MobilinkdInputLevel?, Date?),
             setGain: @escaping (Int) -> Void) {
        cancel()
        self.control = control
        running = true
        resultMessage = nil
        outcome = nil
        task = Task { [weak self] in
            var planner = MobilinkdLevelAssistant(minGain: gains.lowerBound, maxGain: gains.upperBound)
            control.startMeasuringInput()
            defer { control.stopMeasuringInput() }
            while case .measure(let gain) = planner.step {
                self?.status = "Trying \(MobilinkdSettingsSections.gainText(gain))\u{2026}"
                setGain(gain)
                try? await Task.sleep(for: .seconds(Self.settleSeconds))
                guard !Task.isCancelled else { return }
                var samples: [MobilinkdInputLevel] = []
                var lastAt: Date?
                let end = Date().addingTimeInterval(Self.sampleSeconds)
                while Date() < end, !Task.isCancelled {
                    let (level, at) = reading()
                    if let level, let at, at != lastAt { samples.append(level); lastAt = at }
                    try? await Task.sleep(for: .milliseconds(80))
                }
                guard !Task.isCancelled else { return }
                guard !samples.isEmpty else {
                    self?.finish("The TNC4 sent no levels. Try again.")
                    return
                }
                planner.record(samples)
            }
            self?.outcome = planner.step
            switch planner.step {
            case .done(let gain):
                setGain(gain)
                self?.finish("Set to \(MobilinkdSettingsSections.gainText(gain)) for this radio.")
            case .betweenSteps(let gain):
                setGain(gain)
                self?.finish("Set to \(MobilinkdSettingsSections.gainText(gain)). The radio's volume falls between two steps; turn it up a little and run this again for a stronger level.")
            case .radioTooLoud:
                setGain(gains.lowerBound)
                self?.finish("Even the lowest gain clips. Turn the radio's volume down and run this again.")
            case .radioTooQuiet(let gain):
                setGain(gain)
                self?.finish("Even the highest gain is too quiet. Turn the radio's volume up and run this again.")
            case .measure:
                break
            }
        }
    }

    func cancel() {
        guard running else { return }
        task?.cancel()
        task = nil
        control?.stopMeasuringInput()
        finish(nil)
    }

    private func finish(_ message: String?) {
        running = false
        status = nil
        resultMessage = message
    }
}

extension MobilinkdSettingsSections {
    /// Read the TNC4 once a radio's link is up and its Mobilinkd controls are
    /// there, and once more if the report hasn't arrived a few seconds later.
    ///
    /// Run from the radio form, keyed on the link's state, so it happens
    /// whenever the radio comes up while settings are open. It used to hang
    /// off the TNC4 sections themselves, which aren't on screen until the TNC
    /// has identified itself, and the page stayed empty until it was reopened.
    @MainActor
    static func readTNC4WhenUp(radioID: RadioID, client: PacketEngine, state: KISSLinkState) async {
        guard state == .connected else { return }
        // The controls come with the link, a moment after the state flips.
        var control = client.mobilinkdControl(for: radioID)
        for _ in 0..<20 where control == nil {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            control = client.mobilinkdControl(for: radioID)
        }
        guard let control else { return }
        control.refreshMobilinkdStatus()
        try? await Task.sleep(for: .seconds(4))
        if Task.isCancelled { return }
        let device = client.mobilinkdDevices[radioID]
        if device?.batteryMillivolts == nil || device?.hardwareVersion == nil {
            control.refreshMobilinkdStatus()
        }
    }
}
