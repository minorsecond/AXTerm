//
//  ReceiveLevelTuningRows.swift
//  AXTerm
//
//  The receive-level calibration rows in a TNC4 radio's Receive audio
//  section: Calibrate on an APRS radio, the passive recommendation on a
//  packet radio, the last result, and the half-hourly check. See
//  ReceiveLevelMonitor and Docs/MobilinkdTNC4.md.
//

import SwiftUI

struct ReceiveLevelTuningRows: View {
    let radioID: RadioID
    let onAPRS: Bool
    let connected: Bool
    /// A measurement or test tone is running from this page.
    let blocked: Bool
    /// Why the radio's beacon can't go out now. Calibration sends it, so
    /// it waits until this is nil (smoke run 2026-10-03-1, issue 41).
    var beaconObstacle: String?
    @ObservedObject var monitor: ReceiveLevelMonitor
    @State private var confirming = false
    /// Moves on when the calibration spacing runs out. Nothing else redraws
    /// the rows then, and Calibrate stayed disabled until the page was
    /// reopened (smoke run 2026-10-03-1, issue 43).
    @State private var spacingEnded = 0

    var body: some View {
        let record = monitor.record(radioID)
        let state = monitor.calibrations[radioID]
        let next = monitor.nextCalibrationAllowed(radioID)
        let _ = spacingEnded

        LabeledContent("Receive level") {
            if case .running(let status) = state {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                }
            } else if onAPRS {
                Button("Calibrate receive level\u{2026}") { confirming = true }
                    .disabled(!connected || blocked || next != nil || beaconObstacle != nil
                              || monitor.isBusy(radioID))
                    .help("Sends this radio's beacon once, measures how loud the digipeats arrive, and sets the input gain for this radio.")
            } else if let passive = monitor.passiveAdvice(for: radioID) {
                if case .keep = passive.recommendation.action {
                    Text("Input gain is right").foregroundStyle(.secondary)
                } else {
                    Button("Use \(ReceiveGainAdvice.gainText(passive.recommendation.gain))") {
                        monitor.applyPassive(radioID)
                    }
                    .disabled(!connected || monitor.isBusy(radioID))
                }
            } else {
                Text("Listening for packets").foregroundStyle(.secondary)
            }
        }

        if onAPRS, !isRunning(state), let note = Self.beaconNote(beaconObstacle) {
            caption(note)
        }
        if onAPRS, let next, !isRunning(state) {
            caption("To keep the channel clear, the next calibration beacon can go at \(ReceiveLevelMonitor.notBefore(next)).")
                .task(id: next) {
                    let wait = next.timeIntervalSinceNow
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64((wait + 0.5) * 1_000_000_000)) }
                    if !Task.isCancelled { spacingEnded += 1 }
                }
        }
        if !onAPRS { passiveCaption }

        if case .finished(let report) = state {
            VStack(alignment: .leading, spacing: 4) {
                Label(report.message, systemImage: report.succeeded ? "checkmark.circle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(report.succeeded ? Color.primary : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(report.help)
                HStack {
                    if report.succeeded, report.previousGain != nil {
                        Button("Undo") { monitor.undoCalibration(radioID) }
                    }
                    Button("Dismiss") { monitor.dismissCalibration(radioID) }
                }
                .controlSize(.small)
            }
        } else if let baseline = record.baseline {
            caption(ReceiveLevelFinding.baselineLine(baseline, time: ReceiveLevelFinding.defaultTimeText))
        }

        Toggle("Check the level every half hour", isOn: Binding(
            get: { record.watchEnabled },
            set: { monitor.setWatchEnabled($0, for: radioID) }))
            .help("While the radio is connected and idle, AXTerm takes a 2 second level sample about every 30 minutes and says so if the audio has moved since calibration. The TNC4 doesn't decode packets during the sample.")
            .confirmationDialog("Calibrate the receive level?", isPresented: $confirming) {
                Button("Send Beacon and Calibrate") { monitor.calibrate(radioID) }
            } message: {
                Text("AXTerm sends this radio's beacon once, listens about 6 seconds for digipeaters repeating it, and sets this radio's input gain from how loud they arrive. The TNC4 doesn't decode packets while it listens, so those digipeats won't appear in the log. You can undo the change.")
            }
    }

    @ViewBuilder
    private var passiveCaption: some View {
        if let passive = monitor.passiveAdvice(for: radioID) {
            let rec = passive.recommendation
            caption("From \(passive.packets) packets heard during level checks since \(ReceiveLevelMonitor.time(passive.since)): "
                    + "they arrive at \(ReceiveGainAdvice.percent(rec.measuredFraction)) at \(ReceiveGainAdvice.gainText(rec.measuredGain)). "
                    + ReceiveGainAdvice.advice(rec))
        } else {
            let have = monitor.record(radioID).packetLevels.count
            caption("A packet channel gets no calibration beacon. AXTerm recommends a gain once it has caught "
                    + "\(ReceiveLevelAnalysis.passiveMinimumPackets) packets in its level checks (\(min(have, ReceiveLevelAnalysis.passiveMinimumPackets)) so far). "
                    + "Until then, use the level meter above.")
        }
    }

    /// What to say beside Calibrate when the beacon it sends can't go.
    static func beaconNote(_ obstacle: String?) -> String? {
        guard let obstacle else { return nil }
        return "Calibrating sends this radio's beacon, which can't go out yet: \(obstacle)"
    }

    private func isRunning(_ state: ReceiveLevelMonitor.CalibrationState?) -> Bool {
        if case .running = state { return true }
        return false
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The receive-level finding for a radio, with its Retune action, for the
/// radio page's status section.
struct ReceiveLevelFindingRows: View {
    let radioID: RadioID
    let now: Date
    @ObservedObject var monitor: ReceiveLevelMonitor
    /// Opens the receive audio section, for the level meter.
    let showReceiveAudio: () -> Void
    /// Opens the TNC4 tuning wizard, for findings the meter used to answer.
    var openTuning: (() -> Void)?

    var body: some View {
        if let finding = monitor.finding(for: radioID, now: now) {
            Label(finding.message, systemImage: "waveform.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .help(finding.help)
            ReceiveLevelRetuneButton(radioID: radioID, retune: finding.retune, monitor: monitor,
                                     showReceiveAudio: showReceiveAudio, openTuning: openTuning)
        }
    }
}

/// What Retune does for a finding.
struct ReceiveLevelRetuneButton: View {
    let radioID: RadioID
    let retune: ReceiveLevelFinding.Retune
    @ObservedObject var monitor: ReceiveLevelMonitor
    let showReceiveAudio: () -> Void
    var openTuning: (() -> Void)?

    var body: some View {
        switch retune {
        case .calibrate, .turnVolume(_, thenCalibrate: true):
            Button("Retune") {
                monitor.calibrate(radioID)
                showReceiveAudio()
            }
            .disabled(monitor.isBusy(radioID) || monitor.nextCalibrationAllowed(radioID) != nil)
            .help("Sends this radio's beacon once and sets the input gain from how loud the digipeats arrive.")
        case .useGain(let gain):
            Button("Use \(ReceiveGainAdvice.gainText(gain))") { monitor.useGain(gain, for: radioID) }
        case .levelMeter, .turnVolume(_, thenCalibrate: false):
            if let openTuning {
                Button("Tune the TNC4\u{2026}") { openTuning() }
            } else {
                Button("Check the Receive Level\u{2026}") { showReceiveAudio() }
            }
        }
    }
}

/// A quiet offer to tune a TNC4 radio that never has been: a radio just
/// added, or one that has run on the TNC4's own gain all along. Hidden while
/// a receive-level finding is showing, since its button opens the same
/// wizard.
struct TNC4TuningSuggestionRow: View {
    let radioID: RadioID
    let now: Date
    @ObservedObject var monitor: ReceiveLevelMonitor
    let open: () -> Void

    var body: some View {
        if monitor.suggestsTuning(radioID), monitor.finding(for: radioID, now: now) == nil {
            HStack {
                Label("The TNC4's receive level hasn't been tuned for this radio.", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Not Now") { monitor.dismissTuningSuggestion(radioID) }
                Button("Tune\u{2026}") { open() }
            }
            .controlSize(.small)
        }
    }
}
