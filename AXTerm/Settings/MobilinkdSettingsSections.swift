//
//  MobilinkdSettingsSections.swift
//  AXTerm
//
//  The TNC4 part of a radio's settings: what the TNC4 reports, the settings
//  this radio applies to it, audio measurement and test tones, and saving to
//  the TNC4 itself. See Docs/MobilinkdTNC4.md.
//

import SwiftUI

struct MobilinkdSettingsSections: View {
    let radioID: RadioID
    @ObservedObject var client: PacketEngine
    @ObservedObject var viewModel: ConnectionTransportViewModel

    @State private var tone: MobilinkdTestTone = .both
    @State private var confirmingTone = false
    @State private var toneEndsAt: Date?
    @State private var measuring = false
    @State private var confirmingSave = false
    @State private var refreshedOnce = false

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
        if applies {
            Group {
                statusSection
                receiveSection
                transmitSection
                interfaceSection
                saveSection
            }
            .onAppear {
                if connected, !refreshedOnce { refreshedOnce = true; control?.refreshMobilinkdStatus() }
            }
            .onChange(of: connected) { _, isUp in
                if isUp { control?.refreshMobilinkdStatus() }
            }
            .onDisappear {
                control?.stopMeasuringInput()
                control?.stopTestTone()
            }
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
            levelMeter
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
            Text("Measure with the radio's squelch open on a quiet channel, and aim for a level that never touches either end. For the same level, less gain and more radio volume recovers faster after transmitting. Twist is usually 6 dB for a radio's speaker output and 0 dB for flat audio.")
        }
    }

    @ViewBuilder
    private var levelMeter: some View {
        if connected {
            let level = measuring ? device.inputLevel : nil
            LabeledContent("Level") {
                HStack(spacing: 8) {
                    if let level {
                        let fraction = Double(level.vpp) / 65535
                        let clipped = level.vmin == 0 || level.vmax >= 65_400
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
            timing("TX delay", value: $viewModel.txDelayMs, unit: "ms", range: 0...2000, step: 10)
            timing("Persistence", value: $viewModel.persistence, unit: "", range: 0...255, step: 1)
            timing("Slot time", value: $viewModel.slotTimeMs, unit: "ms", range: 10...1000, step: 10)
        } header: {
            Text("Radio interface")
        } footer: {
            Text("Most handhelds use multiplex PTT. TX delay has to cover the time the radio takes to get on the air; some handhelds need 400 to 500 ms. These timing values are sent every time the radio connects.")
        }
    }

    private func timing(_ title: String, value: Binding<Int>, unit: String,
                        range: ClosedRange<Int>, step: Int) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number)
                    .labelsHidden()
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Stepper(title, value: value, in: range, step: step).labelsHidden()
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
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
        if value != nil {
            control(Binding(get: { value ?? fallback }, set: { value = $0 }))
        } else {
            Text("Using the TNC4's own: \(tncValue.map(describe) ?? "not read yet")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
