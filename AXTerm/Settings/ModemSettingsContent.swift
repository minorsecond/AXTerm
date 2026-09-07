import SwiftUI

// The sound modem's half of a radio's form. `RadioDetailView` puts
// `ModemSettingsContent` under the Transport picker and the three sections
// after it; the status rows join the link's status section. All of it
// binds to the per-radio `ConnectionTransportViewModel`.

/// Audio devices and modem mode: the rows that make the link.
struct ModemSettingsContent: View {
    @ObservedObject var viewModel: ConnectionTransportViewModel

    var body: some View {
        #if os(macOS)
        let inputBinding = Binding<String>(
            get: { viewModel.audioInputDeviceUID },
            set: { viewModel.userDidChangeAudioInput($0) })
        let outputBinding = Binding<String>(
            get: { viewModel.audioOutputDeviceUID },
            set: { viewModel.userDidChangeAudioOutput($0) })

        VStack(alignment: .leading, spacing: 12) {
            Picker("Audio in:", selection: inputBinding) {
                Text("Choose a device\u{2026}").tag("")
                Divider()
                ForEach(viewModel.audioInputs) { device in
                    Text(deviceLabel(device)).tag(device.uid)
                }
                if !viewModel.audioInputDeviceUID.isEmpty,
                   !viewModel.audioInputs.contains(where: { $0.uid == viewModel.audioInputDeviceUID }) {
                    Text("\(viewModel.audioInputDeviceUID) (not present)").tag(viewModel.audioInputDeviceUID)
                }
            }
            .help("The device that carries the radio's receive audio. An IC-705 over USB is \u{201C}USB Audio CODEC\u{201D}.")

            Picker("Audio out:", selection: outputBinding) {
                Text("Choose a device\u{2026}").tag("")
                Divider()
                ForEach(viewModel.audioOutputs) { device in
                    Text(deviceLabel(device)).tag(device.uid)
                }
                if !viewModel.audioOutputDeviceUID.isEmpty,
                   !viewModel.audioOutputs.contains(where: { $0.uid == viewModel.audioOutputDeviceUID }) {
                    Text("\(viewModel.audioOutputDeviceUID) (not present)").tag(viewModel.audioOutputDeviceUID)
                }
            }
            .help("The device the modem's transmit audio plays into. Usually the same codec.")

            Picker("Receive from:", selection: $viewModel.audioInputChannel) {
                Text("Left channel").tag(ModemInputChannel.left)
                Text("Right channel").tag(ModemInputChannel.right)
                Text("Both, averaged").tag(ModemInputChannel.mono)
            }
            .help("Which channel of a stereo device carries the radio. The IC-705 puts receive audio on both.")

            Picker("Mode:", selection: $viewModel.modemMode) {
                ForEach(ModemMode.selectable, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text(viewModel.modemMode.radioSetupNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            ModemLevelMeter(telemetry: viewModel.modemTelemetry)
        }
        .padding(.vertical, 4)
        #else
        Text("The sound modem needs a Mac: it decodes the radio's audio through a sound device and keys "
             + "it over a USB serial port. Reach a TNC over the network or Bluetooth from here.")
            .font(.caption)
            .foregroundStyle(.secondary)
        #endif
    }

    private func deviceLabel(_ device: ModemAudioDevice) -> String {
        device.transport.isEmpty ? device.name : "\(device.name) (\(device.transport))"
    }
}

/// The receive level as a bar, coloured the way the Mobilinkd meter is:
/// grey with no audio, green in range, amber hot, red clipping.
struct ModemLevelMeter: View {
    let telemetry: ModemTelemetry?

    var body: some View {
        HStack(spacing: 10) {
            Text("Receive level:")
            ProgressView(value: fraction)
                .tint(tint)
                .frame(maxWidth: 220)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .leading)
        }
        .help("Peak level of the audio reaching the modem, in dB below full scale. Aim for \u{2212}20 to \u{2212}6 dBFS "
              + "on packets: set the radio's AF output (USB AF Output Level on an IC-705) so speech never reaches the red.")
    }

    private var peak: Float { telemetry?.rxPeakDBFS ?? -120 }
    private var fraction: Double { Double(max(0, min(1, (peak + 60) / 60))) }
    private var tint: Color {
        guard telemetry != nil else { return .gray }
        if telemetry?.rxClipping == true || peak > -1 { return .red }
        if peak > -6 { return .orange }
        if peak > -40 { return .green }
        return .gray
    }
    private var label: String {
        guard telemetry != nil else { return "Not running" }
        if peak <= -100 { return "Silence" }
        return String(format: "%.0f dBFS%@", peak, telemetry?.rxClipping == true ? " · clipping" : "")
    }
}

/// CI-V: the port, the address, and what the radio says when asked.
struct ModemRigSection: View {
    @ObservedObject var viewModel: ConnectionTransportViewModel

    var body: some View {
        Section {
            Picker("CI-V port", selection: $viewModel.civSerialPath) {
                Text("None (audio only)").tag("")
                Divider()
                ForEach(viewModel.serialDevices) { device in
                    Text(device.displayName).tag(device.path)
                }
                if !viewModel.civSerialPath.isEmpty,
                   !viewModel.serialDevices.contains(where: { $0.path == viewModel.civSerialPath }) {
                    Text("\(viewModel.civSerialPath) (not present)").tag(viewModel.civSerialPath)
                }
            }
            .help("The radio's control port. An IC-705 over USB shows two usbmodem ports; the lower-numbered one is Port A, the CI-V port.")

            LabeledContent("CI-V address") {
                TextField("A4", text: $viewModel.civAddressHex)
                    .labelsHidden()
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            .help("The radio's own CI-V address in hex. IC-705: A4. IC-7300: 94. IC-9700: 98. The radio's menu shows it under CI-V.")

            Picker("Keying", selection: $viewModel.pttMethod) {
                ForEach(ModemPTTMethod.allCases, id: \.self) { method in
                    Text(method.title).tag(method)
                }
            }
            Text(viewModel.pttMethod.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent {
                HStack(spacing: 8) {
                    Button(viewModel.isIdentifying ? "Asking\u{2026}" : "Identify") { viewModel.identifyRig() }
                        .disabled(viewModel.isIdentifying || viewModel.civSerialPath.isEmpty)
                        .controlSize(.small)
                    if let result = viewModel.identifyResult {
                        Text(result)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(result.hasPrefix("No answer") ? .red : .primary)
                    } else if !viewModel.rigModel.isEmpty {
                        Text(viewModel.rigModel)
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                Text("Radio")
            }
            .help("Sends the CI-V identify command on the chosen port and reads the frequency and mode back. Nothing is transmitted on the air.")
        } header: {
            Text("Rig control (CI-V)")
        } footer: {
            Text("AXTerm keys the radio and reads its frequency over CI-V, so the radio's frequency and mode appear "
                 + "beside this radio wherever it is listed. With no port the modem only listens and the radio keys on VOX.")
        }
    }
}

/// Drive level, timing, and the two tests.
struct ModemTransmitSection: View {
    @ObservedObject var viewModel: ConnectionTransportViewModel

    var body: some View {
        Section {
            LabeledContent("Transmit level") {
                HStack(spacing: 10) {
                    Slider(value: $viewModel.txAudioLevel, in: 0...100, step: 1)
                        .frame(maxWidth: 220)
                    Text("\(Int(viewModel.txAudioLevel))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
            .help("Transmit audio level, 0\u{2013}100 (\u{2212}40 to 0 dBFS). Set it with the test tone so the radio's ALC barely moves; "
                  + "an IC-705 also has USB MOD Level in its menu.")

            LabeledContent {
                HStack(spacing: 8) {
                    Button(viewModel.isSendingTestTone ? "Sending\u{2026}" : "Test tone (2 s)") { viewModel.sendTestTone() }
                        .disabled(viewModel.connectionStatus != .connected || viewModel.isSendingTestTone)
                        .controlSize(.small)
                    Button("Send test frame") { viewModel.sendTestFrame() }
                        .disabled(viewModel.connectionStatus != .connected)
                        .controlSize(.small)
                }
            } label: {
                Text("Tests")
                if let message = viewModel.modemActionMessage {
                    Text(message)
                }
            }
            .help("The tone keys the radio and plays a steady 1200 Hz mark for two seconds. The test frame is a UI frame to TEST "
                  + "from this radio's callsign, sent through the normal path so another station's decoder can confirm the chain.")

            timingRow("TXDELAY", value: $viewModel.txDelayMs, unit: "ms", range: 0...2000, step: 10,
                      help: "Preamble before the first frame, so the radio is fully on the air. 300 ms suits an IC-705 over USB; "
                          + "shorten it once frames decode reliably at the other end.")
            timingRow("TXTAIL", value: $viewModel.txTailMs, unit: "ms", range: 0...1000, step: 10,
                      help: "Flags after the last frame before PTT drops, covering the USB audio path's delay.")
            timingRow("Persistence", value: $viewModel.persistence, unit: "", range: 0...255, step: 1,
                      help: "P of p-persistence CSMA: the chance in 256 of transmitting each slot once the channel is clear. 63 is the "
                          + "customary quarter; lower it on a busy channel.")
            timingRow("Slot time", value: $viewModel.slotTimeMs, unit: "ms", range: 10...1000, step: 10,
                      help: "How long to wait between rolls of the persistence dice.")
            timingRow("Max transmission", value: $viewModel.maxTransmitSeconds, unit: "s", range: 3...120, step: 1,
                      help: "The watchdog: PTT is forced off after this long no matter what, so a fault cannot hold the transmitter.")
        } header: {
            Text("Transmit")
        }
    }

    private func timingRow(_ title: String, value: Binding<Int>, unit: String, range: ClosedRange<Int>, step: Int, help: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number)
                    .labelsHidden()
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                if !unit.isEmpty {
                    Text(unit)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                }
            }
        }
        .help(help)
    }
}

/// What AXTerm may do to the radio itself.
struct ModemRadioSection: View {
    @ObservedObject var viewModel: ConnectionTransportViewModel
    @State private var confirmingSetup = false

    var body: some View {
        Section {
            Toggle("Follow the radio's frequency", isOn: $viewModel.followsRadioFrequency)
                .help("Read the frequency and mode every few seconds while idle, so the sidebar and the radio agree after you tune.")
            Toggle("Set the radio for packet when connecting", isOn: $viewModel.setsRadioModeOnConnect)
                .help("Push the settings below each time this radio connects. Off by default: the radio is yours.")
            LabeledContent {
                Button("Set radio for packet\u{2026}") { confirmingSetup = true }
                    .disabled(viewModel.connectionStatus != .connected || viewModel.civSerialPath.isEmpty)
                    .controlSize(.small)
            } label: {
                Text("Radio setup")
                Text(viewModel.modemMode.radioSetupNote)
            }
            .confirmationDialog("Set the radio for packet?", isPresented: $confirmingSetup, titleVisibility: .visible) {
                Button("Set radio") { viewModel.configureRadioForPacket() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(Self.setupDescription(for: viewModel.modemMode))
            }
        } header: {
            Text("Radio")
        }
    }

    /// Exactly what `configureForPacket` pushes, in the operator's words.
    static func setupDescription(for mode: ModemMode) -> String {
        let modeLine: String
        switch mode {
        case .afsk1200: modeLine = "Mode FM with data mode on (FM-D)."
        case .afsk300: modeLine = "Mode USB with data mode on (USB-D), filter 1."
        case .g3ruh9600RxIF: modeLine = "Mode FM with data mode on (FM-D)."
        }
        return [modeLine,
                "DATA MOD input: USB.",
                "USB SEND: OFF (AXTerm keys the radio over CI-V).",
                "AF squelch: open, so the modem hears the channel.",
                "The frequency is not touched."].joined(separator: "\n")
    }
}

/// The connected modem's vital signs, in the status section.
struct ModemStatusRows: View {
    @ObservedObject var viewModel: ConnectionTransportViewModel

    var body: some View {
        if let telemetry = viewModel.modemTelemetry {
            LabeledContent("Channel") {
                HStack(spacing: 12) {
                    dot(telemetry.dcd, on: .green, "Carrier")
                    dot(telemetry.ptt, on: .red, "PTT")
                    if telemetry.waitingForChannel {
                        Text("waiting for a clear channel")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .help("Carrier: the modem hears packet activity (from its decoder, not the radio's squelch). PTT: this radio is transmitting.")

            LabeledContent("Frames") {
                Text("\(telemetry.framesDecoded) decoded \u{b7} \(telemetry.fcsErrors) failed checksum \u{b7} \(telemetry.framesSent) sent")
                    .font(.callout.monospacedDigit())
            }
            .help("Failed checksums are frames heard but not decoded; a few are normal, many with a healthy level means the audio is too hot or too quiet.")

            if let format = telemetry.audioFormat {
                LabeledContent("Audio") {
                    Text(String(format: "%.0f kHz \u{b7} %d in \u{b7} %d out%@",
                                format.sampleRate / 1000, format.inputChannels, format.outputChannels,
                                telemetry.rxOverruns + telemetry.txUnderruns > 0
                                    ? " \u{b7} \(telemetry.rxOverruns + telemetry.txUnderruns) dropouts" : ""))
                        .font(.callout.monospacedDigit())
                }
            }
        }
        if let rig = viewModel.rigStatus, let frequency = rig.frequencyLabel {
            LabeledContent("Radio") {
                Text([viewModel.rigModel.isEmpty ? nil : viewModel.rigModel, frequency, rig.modeLabel]
                        .compactMap { $0 }.joined(separator: " \u{b7} "))
                    .font(.callout.monospacedDigit())
            }
            .help("As the radio reports it over CI-V. Refreshed every five seconds while the modem is idle.")
        }
    }

    private func dot(_ on: Bool, on color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on ? color : Color(platform: .platformTertiaryLabel))
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundStyle(on ? .primary : .secondary)
        }
    }
}
