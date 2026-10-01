//
//  TNC4TuningSheet.swift
//  AXTerm
//
//  Tuning a TNC4's receive level, one step at a time: the input gain with
//  the squelch open, the squelch back, then a check against real packets.
//  The pieces are the radio page's own (the gain finder, calibration, the
//  packet-based advice); this puts them in order. See TNC4TuningFlow for
//  what Cancel puts back.
//

import SwiftUI

struct TNC4TuningSheet: View {
    @ObservedObject var flow: TNC4TuningFlow
    @ObservedObject var client: PacketEngine
    @ObservedObject var viewModel: ConnectionTransportViewModel
    @ObservedObject var monitor: ReceiveLevelMonitor
    /// Called once, when the sheet is finished or canceled.
    let onClose: () -> Void

    @StateObject private var finder = MobilinkdLevelAssistantRunner()

    /// How long the packet check listens on a packet channel.
    static let listenSeconds: TimeInterval = 30

    private var radioID: RadioID { flow.radioID }
    private var device: MobilinkdDeviceState { client.mobilinkdDevices[radioID] ?? MobilinkdDeviceState() }
    private var control: MobilinkdControlling? { client.mobilinkdControl(for: radioID) }
    private var connected: Bool { viewModel.radioConnected && control != nil }
    private var gains: ClosedRange<Int> { (device.minInputGain ?? 0)...(device.maxInputGain ?? 4) }

    var body: some View {
        SetupFrame(title: "Tune the TNC4",
                   subtitle: subtitle,
                   steps: TNC4TuningFlow.Step.allCases.map(\.title),
                   current: flow.step.rawValue) {
            content
        } buttons: {
            buttons
        }
        .interactiveDismissDisabled()
        .onChange(of: finder.outcome) { _, outcome in
            if let outcome { flow.recordGainOutcome(outcome) }
        }
        .onDisappear {
            finder.cancel()
            flow.cancel()
        }
    }

    // MARK: Frame

    private var subtitle: String {
        switch flow.step {
        case .start: return "Sets how loud \(flow.radioName)'s audio reaches the TNC4, so packets decode cleanly."
        case .receiveGain: return "Measured on the radio's noise with the squelch open."
        case .squelch: return "Back to normal before checking real packets."
        case .packets: return flow.packetCheck == .beacon
            ? "Checked against how loud the digipeaters' repeats arrive."
            : "Checked against packets from other stations."
        case .done: return "Done keeps these settings for this radio."
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Cancel", role: .cancel) {
            finder.cancel()
            flow.cancel()
            onClose()
        }
        .keyboardShortcut(.cancelAction)
        Spacer()
        if flow.canGoBack {
            Button("Back") { flow.back() }
                .disabled(busy)
        }
        if flow.step == .done {
            Button("Done") {
                flow.finish()
                onClose()
            }
            .keyboardShortcut(.defaultAction)
        } else {
            Button("Next") { flow.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.canContinue || busy || (flow.step == .start && !connected))
        }
    }

    /// Something is measuring; moving on would leave it running unseen.
    private var busy: Bool { finder.running || monitor.isBusy(radioID) }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .start: startStep
        case .receiveGain: receiveGainStep
        case .squelch: squelchStep
        case .packets: packetsStep
        case .done: doneStep
        }
    }

    // MARK: Steps

    private var startStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("First you open the radio's squelch for about half a minute while AXTerm tries each input gain, and it keeps the lowest one that gives a clean level. Then you close the squelch and AXTerm checks the result against real packets.")
            Text("Whatever this changes is this radio's own setting. Nothing is saved to the TNC4: it gets its own settings back when this radio disconnects, so another radio sharing it isn't affected. Cancel puts everything back.")
                .foregroundStyle(.secondary)
            LabeledContent("Input gain now", value: currentGainText)
            if !connected {
                Label("Connect the radio first.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var receiveGainStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open the radio's squelch fully on a quiet channel, so you hear steady noise and no one talking. Leave the volume where you normally have it.")
                .fixedSize(horizontal: false, vertical: true)
            levelMeter
            HStack {
                if finder.running {
                    ProgressView().controlSize(.small)
                    Text(finder.status ?? "").foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { finder.cancel() }
                } else {
                    Button(flow.gainOutcome == nil ? "Find the Gain" : "Try Again") { runFinder() }
                        .disabled(!connected)
                }
            }
            if let message = finder.resultMessage {
                Label(message, systemImage: flow.canContinue ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(flow.canContinue ? Color.primary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Packets aren't received while AXTerm measures. It takes about half a minute.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var levelMeter: some View {
        let level = finder.running ? device.inputLevel : nil
        LabeledContent("Level") {
            HStack(spacing: 8) {
                ProgressView(value: level?.fraction ?? 0)
                    .tint(level?.clipped == true ? .red : (level?.fraction ?? 0) < 0.1 ? .orange : .green)
                    .frame(width: 160)
                Text(level.map { $0.clipped ? "Clipping" : "\(Int($0.fraction * 100))%" } ?? "\u{2014}")
                    .monospacedDigit()
                    .foregroundStyle(level?.clipped == true ? .red : .secondary)
                    .frame(width: 64, alignment: .leading)
            }
        }
    }

    private var squelchStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Turn the squelch back to where you normally keep it.")
            LabeledContent("Input gain", value: currentGainText)
        }
    }

    @ViewBuilder
    private var packetsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch flow.packetCheck {
            case .beacon: beaconCheck
            case .listen: listenCheck
            }
            Text("You can skip this. AXTerm keeps an eye on the level about every half hour while the radio is connected and says so if it moves.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var beaconCheck: some View {
        Text("AXTerm sends this radio's beacon once, listens about 6 seconds for digipeaters repeating it, and sets the input gain from how loud they arrive.")
            .fixedSize(horizontal: false, vertical: true)
        let next = monitor.nextCalibrationAllowed(radioID)
        switch monitor.calibrations[radioID] {
        case .running(let status):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(status).foregroundStyle(.secondary)
            }
        case .finished(let report):
            Label(report.message, systemImage: report.succeeded ? "checkmark.circle" : "info.circle")
                .fixedSize(horizontal: false, vertical: true)
                .help(report.help)
        case nil:
            Button("Send Beacon and Measure") { monitor.calibrate(radioID) }
                .disabled(!connected || next != nil || monitor.isBusy(radioID))
            if let next {
                Text("To keep the channel clear, the next calibration beacon can go at \(ReceiveLevelMonitor.time(next)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var listenCheck: some View {
        Text("AXTerm listens for other stations for \(Int(Self.listenSeconds)) seconds and measures how loud their packets arrive. It needs \(ReceiveLevelAnalysis.passiveMinimumPackets) packets, from these listens and its half-hourly checks, before it suggests a gain.")
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            if monitor.isListening(radioID) {
                ProgressView().controlSize(.small)
                Text("Listening\u{2026}").foregroundStyle(.secondary)
            } else {
                Button("Listen for \(Int(Self.listenSeconds)) Seconds") {
                    monitor.listen(radioID, seconds: Self.listenSeconds)
                }
                .disabled(!connected || monitor.isBusy(radioID))
            }
        }
        if let passive = monitor.passiveAdvice(for: radioID) {
            let rec = passive.recommendation
            Text("From \(passive.packets) packets: they arrive at \(ReceiveGainAdvice.percent(rec.measuredFraction)) at \(ReceiveGainAdvice.gainText(rec.measuredGain)). " + ReceiveGainAdvice.advice(rec))
                .fixedSize(horizontal: false, vertical: true)
            if case .keep = rec.action {
                Label("The input gain is right.", systemImage: "checkmark.circle")
            } else {
                Button("Use \(ReceiveGainAdvice.gainText(rec.gain))") { monitor.applyPassive(radioID) }
                    .disabled(!connected || monitor.isBusy(radioID))
            }
        } else {
            let have = min(monitor.record(radioID).packetLevels.count, ReceiveLevelAnalysis.passiveMinimumPackets)
            Text("\(have) of \(ReceiveLevelAnalysis.passiveMinimumPackets) packets heard so far.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(flow.gainSummary)
            if let baseline = monitor.record(radioID).baseline {
                Text(ReceiveLevelFinding.baselineLine(baseline, time: ReceiveLevelFinding.defaultTimeText))
                    .foregroundStyle(.secondary)
            }
            Text("Nothing was saved to the TNC4. It gets its own settings back when this radio disconnects.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private var currentGainText: String {
        if let gain = viewModel.tnc4.inputGain { return ReceiveGainAdvice.gainText(gain) }
        if let own = device.inputGain { return "The TNC4's own, \(ReceiveGainAdvice.gainText(own))" }
        return "The TNC4's own"
    }

    private func runFinder() {
        guard let control else { return }
        flow.retryGain()
        let id = radioID
        finder.run(control: control, gains: gains,
                   reading: { [client] in
                       let d = client.mobilinkdDevices[id]
                       return (d?.inputLevel, d?.inputLevelAt)
                   },
                   setGain: { [viewModel] in viewModel.tnc4.inputGain = $0 })
    }
}

extension TNC4TuningFlow {
    /// A wizard for the radio a settings page is showing, reading and writing
    /// the radio's gain through the page's own view model, so the TNC4 gets
    /// every change the way the page's own picker sends it.
    static func forRadio(_ radioID: RadioID, name: String, onAPRS: Bool,
                         client: PacketEngine, viewModel: ConnectionTransportViewModel) -> TNC4TuningFlow {
        TNC4TuningFlow(radioID: radioID, radioName: name, onAPRS: onAPRS,
                       tncGain: client.mobilinkdDevices[radioID]?.inputGain,
                       readGain: { [weak viewModel] in viewModel?.tnc4.inputGain },
                       writeGain: { [weak viewModel] in viewModel?.tnc4.inputGain = $0 })
    }
}
