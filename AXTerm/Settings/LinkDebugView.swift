//
//  LinkDebugView.swift
//  AXTerm
//
//  Settings tab for link-level debug diagnostics.
//  Shows live stats, KISS init config, state timeline,
//  frame log, and parse errors.
//

import SwiftUI

struct LinkDebugView: View {
    @StateObject private var viewModel: LinkDebugViewModel
    @State private var autoScroll = true
    @State private var expandedFrameIDs: Set<UUID> = []

    init(packetEngine: PacketEngine? = nil) {
        _viewModel = StateObject(wrappedValue: LinkDebugViewModel(packetEngine: packetEngine))
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        Form {
            // MARK: - Audio Input Levels (Mobilinkd)
            Section("Audio Input Levels") {
                if let level = viewModel.inputLevel {
                    VStack(alignment: .leading, spacing: 8) {
                        audioLevelBar(label: "Vpp", value: level.vpp)
                        audioLevelBar(label: "Vavg", value: level.vavg)
                        audioLevelBar(label: "Vmin", value: level.vmin)
                        audioLevelBar(label: "Vmax", value: level.vmax)
                    }

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            StatLabel("Vpp")
                            StatValue("\(level.vpp)")
                            StatLabel("Vavg")
                            StatValue("\(level.vavg)")
                        }
                        GridRow {
                            StatLabel("Vmin")
                            StatValue("\(level.vmin)")
                            StatLabel("Vmax")
                            StatValue("\(level.vmax)")
                        }
                    }
                    .font(.system(.body, design: .monospaced))

                    // Optimal range guidance
                    Text(inputLevelGuidance(level))
                        .font(.caption)
                        .foregroundStyle(inputLevelColor(level))
                        .padding(.top, 2)
                } else {
                    Text("No measurement yet (Mobilinkd only)")
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    Button {
                        viewModel.measureInputLevels()
                    } label: {
                        if viewModel.isMeasuring {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                            Text("Measuring...")
                        } else {
                            Text("Measure Levels")
                        }
                    }
                    .disabled(viewModel.isMeasuring)
                    .help("Takes a one-shot audio measurement. Briefly pauses packet reception.")

                    Spacer()

                    Button("Auto Adjust") {
                        viewModel.adjustInputLevels()
                    }
                    .disabled(viewModel.isMeasuring)
                    .help("Runs the TNC4's AGC algorithm. Pauses reception for ~5s.")
                }

                Divider()

                HStack {
                    Text("Input Gain")
                    Stepper(
                        gainLabel(viewModel.inputGain),
                        value: Binding(
                            get: { Int(viewModel.inputGain) },
                            set: { viewModel.setInputGain(UInt8(clamping: $0)) }
                        ),
                        in: 0...4
                    )
                }
            }

            // MARK: - Live Stats
            Section("Live Stats") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        StatLabel("RX Bytes")
                        StatValue("\(viewModel.log.totalBytesIn)")
                        StatLabel("TX Bytes")
                        StatValue("\(viewModel.log.totalBytesOut)")
                    }
                    GridRow {
                        StatLabel("AX.25 Frames")
                        StatValue("\(viewModel.log.ax25FrameCount)")
                        StatLabel("Telemetry")
                        StatValue("\(viewModel.log.telemetryFrameCount)")
                    }
                    GridRow {
                        StatLabel("Unknown Frames")
                        StatValue("\(viewModel.log.unknownFrameCount)")
                        StatLabel("Parse Errors")
                        StatValue("\(viewModel.log.parseErrorCount)")
                            .foregroundStyle(viewModel.log.parseErrorCount > 0 ? .red : .secondary)
                    }
                }
                .font(.system(.body, design: .monospaced))
            }

            // MARK: - KISS Init Config
            if !viewModel.log.configEntries.isEmpty {
                Section("KISS Init Config") {
                    ForEach(viewModel.log.configEntries) { entry in
                        HStack {
                            Text(entry.label)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(entry.rawBytes.hexString)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // MARK: - Link State Timeline
            if !viewModel.log.stateTimeline.isEmpty {
                Section("Link State Timeline") {
                    ForEach(viewModel.log.stateTimeline.reversed()) { entry in
                        HStack(spacing: 8) {
                            Text(Self.timestampFormatter.string(from: entry.timestamp))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.fromState)
                                .font(.system(.caption, design: .monospaced))
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(entry.toState)
                                .font(.system(.caption, design: .monospaced))
                                .bold()
                            Spacer()
                            Text(entry.endpoint)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            // MARK: - Frame Log
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    // Toolbar
                    HStack(spacing: 8) {
                        TextField("Filter...", text: $viewModel.frameFilter)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)

                        Picker("Direction", selection: directionBinding) {
                            Text("All").tag(0)
                            Text("TX").tag(1)
                            Text("RX").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)

                        Spacer()

                        Toggle("Auto-scroll", isOn: $autoScroll)
                            .toggleStyle(.checkbox)

                        Button("Clear") {
                            viewModel.clear()
                        }
                    }
                    .padding(.bottom, 4)

                    // Frame list
                    let filtered = viewModel.filteredFrames
                    if filtered.isEmpty {
                        Text("No frames recorded")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    ForEach(filtered) { entry in
                                        frameRow(entry)
                                            .id(entry.id)
                                    }
                                }
                            }
                            .frame(minHeight: 150, maxHeight: 300)
                            .onChange(of: filtered.count) { _ in
                                if autoScroll, let last = filtered.last {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Frame Log (\(viewModel.filteredFrames.count))")
            }

            // MARK: - Parse Errors
            if !viewModel.log.parseErrors.isEmpty {
                Section("Parse Errors (\(viewModel.log.parseErrors.count))") {
                    ForEach(viewModel.log.parseErrors.suffix(20).reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(Self.timestampFormatter.string(from: entry.timestamp))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.red)
                            }
                            if let raw = entry.rawBytes {
                                Text(raw.truncatedHex(maxBytes: 64))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Subviews

    private func frameRow(_ entry: LinkDebugFrameEntry) -> some View {
        let isExpanded = expandedFrameIDs.contains(entry.id)

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                Text(entry.direction.rawValue)
                    .font(.system(.caption2, design: .monospaced).bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(entry.direction == .tx ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
                    .cornerRadius(3)

                Text(entry.frameType)
                    .font(.system(.caption2, design: .monospaced))

                Text("\(entry.byteCount)B")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                if entry.rawBytes.count > 256 {
                    Button(isExpanded ? "Less" : "More") {
                        if isExpanded {
                            expandedFrameIDs.remove(entry.id)
                        } else {
                            expandedFrameIDs.insert(entry.id)
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                }
            }

            Text(isExpanded ? entry.rawBytes.hexString : entry.rawBytes.truncatedHex())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(isExpanded ? nil : 2)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Audio Level Helpers

    // TNC4 12-bit ADC range
    private static let adcMax: Double = 4096
    // Optimal Vpp range for AFSK1200 demodulation (empirical from TNC4 firmware)
    private static let optimalVppMin: UInt16 = 200
    private static let optimalVppMax: UInt16 = 3000

    private func audioLevelBar(label: String, value: UInt16) -> some View {
        let fraction = min(Double(value) / Self.adcMax, 1.0)
        return HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fraction > 0.9 ? Color.red : (fraction > 0.6 ? Color.orange : Color.green))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 12)
            Text("\(value)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 45, alignment: .trailing)
        }
    }

    private func gainLabel(_ level: UInt8) -> String {
        let db = Int(level) * 6
        return "\(level) (\(db)dB)"
    }

    private func inputLevelGuidance(_ level: MobilinkdInputLevel) -> String {
        if level.vpp < Self.optimalVppMin {
            return "Vpp \(level.vpp) is LOW — audio input too quiet. Increase gain or radio volume."
        } else if level.vpp > Self.optimalVppMax {
            return "Vpp \(level.vpp) is HIGH — audio input too loud. Decrease gain or radio volume."
        } else {
            return "Vpp \(level.vpp) is in the optimal range (\(Self.optimalVppMin)-\(Self.optimalVppMax))."
        }
    }

    private func inputLevelColor(_ level: MobilinkdInputLevel) -> Color {
        if level.vpp < Self.optimalVppMin || level.vpp > Self.optimalVppMax {
            return .orange
        }
        return .green
    }

    // MARK: - Helpers

    private var directionBinding: Binding<Int> {
        Binding<Int>(
            get: {
                if viewModel.showTxOnly { return 1 }
                if viewModel.showRxOnly { return 2 }
                return 0
            },
            set: { value in
                viewModel.showTxOnly = (value == 1)
                viewModel.showRxOnly = (value == 2)
            }
        )
    }
}

// MARK: - Stat Helpers

private struct StatLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 110, alignment: .leading)
    }
}

private struct StatValue: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .frame(width: 80, alignment: .trailing)
    }
}
