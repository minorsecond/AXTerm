//
//  TNC4TuningFlow.swift
//  AXTerm
//
//  The state behind the TNC4 tuning wizard: which step it is on, whether the
//  receive gain it found can be used, and how to leave the radio as it was
//  when the operator cancels. See TNC4TuningSheet.
//

import Combine
import Foundation

/// Tuning a TNC4's receive level for one radio, one step at a time.
///
/// Everything it changes is the radio's own input gain setting, which AXTerm
/// applies to the TNC4 while this radio is connected and takes back when it
/// disconnects. Nothing is written to the TNC4's memory. Canceling puts the
/// radio's setting back to what it was when the wizard opened, including
/// "use the TNC4's own", whatever the gain finder tried on the way.
@MainActor
final class TNC4TuningFlow: ObservableObject, Identifiable {

    enum Step: Int, CaseIterable, Comparable {
        case start
        case receiveGain
        case squelch
        case packets
        case done

        var title: String {
            switch self {
            case .start: return "Start"
            case .receiveGain: return "Receive Gain"
            case .squelch: return "Squelch"
            case .packets: return "Packets"
            case .done: return "Done"
            }
        }

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    /// How the packets step checks the gain against real traffic.
    enum PacketCheck: Equatable {
        /// APRS: one beacon, measured as the digipeaters repeat it.
        case beacon
        /// Packet: listen for other stations for a while.
        case listen
    }

    let id = UUID()
    let radioID: RadioID
    let radioName: String
    let onAPRS: Bool
    /// The gain the TNC4 itself holds, for the summary. Nil if unread.
    let tncGain: Int?
    /// The radio's own gain setting when the wizard opened. Nil means the
    /// radio used the TNC4's own.
    let originalGain: Int?

    @Published var step: Step = .start
    /// Where the gain finder ended, once it has run.
    @Published private(set) var gainOutcome: MobilinkdLevelAssistant.Step?

    private let readGain: () -> Int?
    private let writeGain: (Int?) -> Void
    /// Set once the wizard has been finished or canceled, so the other can't
    /// run as well (the sheet also cancels when it goes away).
    private(set) var isClosed = false

    init(radioID: RadioID, radioName: String, onAPRS: Bool, tncGain: Int?,
         readGain: @escaping () -> Int?, writeGain: @escaping (Int?) -> Void) {
        self.radioID = radioID
        self.radioName = radioName
        self.onAPRS = onAPRS
        self.tncGain = tncGain
        self.readGain = readGain
        self.writeGain = writeGain
        originalGain = readGain()
    }

    var packetCheck: PacketCheck { onAPRS ? .beacon : .listen }

    var canGoBack: Bool { step > .start }

    /// Only the receive gain step can hold the operator back: Next waits for
    /// a gain that can be used. Clipping even at the lowest gain can't be;
    /// the radio's volume has to come down first.
    var canContinue: Bool {
        guard step == .receiveGain else { return true }
        switch gainOutcome {
        case .done, .betweenSteps, .radioTooQuiet: return true
        case .radioTooLoud, .measure, nil: return false
        }
    }

    func next() {
        guard canContinue, let following = Step(rawValue: step.rawValue + 1) else { return }
        step = following
    }

    func back() {
        guard canGoBack, let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    func recordGainOutcome(_ outcome: MobilinkdLevelAssistant.Step) {
        gainOutcome = outcome
    }

    /// Forget the last result, to run the finder again.
    func retryGain() {
        gainOutcome = nil
    }

    /// Keep what the wizard set.
    func finish() {
        isClosed = true
    }

    /// Put the radio's gain setting back as it was when the wizard opened.
    func cancel() {
        guard !isClosed else { return }
        isClosed = true
        if readGain() != originalGain { writeGain(originalGain) }
    }

    // MARK: Summary

    /// The radio's input gain now, against what it was.
    var gainSummary: String {
        let now = readGain()
        if now == originalGain {
            return "Input gain for \(radioName): unchanged, \(describe(now))."
        }
        return "Input gain for \(radioName): \(describe(now)). It was \(describe(originalGain))."
    }

    private func describe(_ gain: Int?) -> String {
        if let gain { return ReceiveGainAdvice.gainText(gain) }
        if let tncGain { return "the TNC4's own, \(ReceiveGainAdvice.gainText(tncGain))" }
        return "the TNC4's own"
    }
}
