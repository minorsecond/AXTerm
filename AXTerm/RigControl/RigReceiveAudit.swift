import Foundation

/// What the radio's own settings say about its ability to hear packet.
///
/// A soundmodem is only ever as good as the audio it is given, and most of
/// what ruins that audio is a menu setting rather than a fault. The radio
/// knows all of it and will say so over CI-V, which is a great deal cheaper
/// than an afternoon of swapping antennas.
///
/// Written after comparing K0EPI-7's own reception against the APRS-IS feed on
/// 2026-09-09: the station heard mountaintop digipeaters at 90 km directly and
/// never once heard a mobile at 10 km except through a digipeater. That shape
/// — strong signals fine, ordinary signals absent — is what an attenuator, a
/// backed-off RF gain or a narrow filter does, and all three are one CI-V read
/// away from being ruled in or out.
///
/// This judges only settings we can read without guessing. Icom's CI-V has
/// subcommands for a great many other things; the ones here are the standard,
/// well-documented set, and nothing is inferred from a command whose meaning
/// on this radio is uncertain.
nonisolated enum RigReceiveAudit {

    struct Settings: Equatable, Sendable {
        /// Attenuator in dB; 0 is off.
        var attenuatorDB: Int
        /// 0 off, 1 P.AMP1, 2 P.AMP2.
        var preamp: Int
        var noiseBlanker: Bool
        var noiseReduction: Bool
        /// 0–100, where 100 is fully clockwise (no reduction).
        var rfGainPercent: Int
        /// 0–100, where 0 is fully open.
        var squelchPercent: Int
        var mode: RigMode
        /// 1 = wide, 2 = mid, 3 = narrow.
        var filter: Int
        var dataMode: Bool
        /// Whether the radio answered anything at all. A settings struct full
        /// of benign defaults because every read timed out must not be judged
        /// as a healthy radio.
        var answered: Bool = true
    }

    enum Severity: Int, Comparable, Sendable {
        /// Costs real sensitivity: this is why frames are missing.
        case blocking = 0
        /// Reshapes the audio the demodulator reads.
        case degrading = 1
        /// Worth trying, not a fault.
        case suggestion = 2

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// A change to the radio that corrects a finding.
    ///
    /// Only settings whose right value for packet is not a matter of taste.
    /// The mode and the preamp deliberately have none: the operator may be in
    /// USB on purpose, and whether a preamp helps is a judgement about the
    /// band rather than a fault to be repaired.
    enum Correction: Equatable, Sendable {
        case attenuatorOff
        case rfGainFull
        case squelchOpen
        case noiseReductionOff
        case noiseBlankerOff
        case widestFilter
    }

    struct Finding: Equatable, Sendable, Identifiable {
        var id: String { title }
        var title: String
        /// What the radio is actually set to, in its own terms.
        var detail: String
        /// What to change. A finding the operator cannot act on is noise.
        var fix: String
        var severity: Severity
        /// The same change, for us to make over CI-V. Nil where the right
        /// value is the operator's judgement rather than a fact.
        var correction: Correction?
    }

    /// Everything worth saying about these settings, worst first.
    ///
    /// `modemMode` is what the modem is set to, and every judgement about the
    /// radio's mode and filter depends on it. Without it this judged every
    /// station as though it were 1200 bd FM on 2 m: a 300 bd HF station was
    /// told, at blocking severity, to switch to FM — and the filter check sat
    /// behind that same `else`, so the one setting that actually matters at
    /// 300 bd was never looked at.
    static func findings(_ s: Settings, for modemMode: ModemMode) -> [Finding] {
        var out: [Finding] = []
        let wantedMode = modemMode.expectedRigMode

        if s.attenuatorDB > 0 {
            out.append(Finding(
                title: "The attenuator is on",
                detail: "Set to \(s.attenuatorDB) dB, which is thrown away before "
                      + "anything else happens.",
                fix: modemMode.ridesOnSSB
                    ? "Turn the attenuator off. On a loud HF band it may well be deliberate, "
                    + "but the packet signal you are trying to decode is rarely the loud thing, "
                    + "and this comes off it first."
                    : "Turn the attenuator off. On 2 m packet there is almost never a "
                    + "reason for it, and it costs exactly the margin a distant station needs.",
                severity: .blocking, correction: .attenuatorOff))
        }

        if s.rfGainPercent < 90 {
            out.append(Finding(
                title: "RF gain is backed off",
                detail: "At \(s.rfGainPercent)% rather than fully clockwise.",
                fix: "Turn RF gain fully up. Backing it off raises the level a signal "
                   + "must reach before the receiver hears it at all — easy to leave "
                   + "behind after chasing noise on another band.",
                severity: .blocking, correction: .rfGainFull))
        }

        if s.squelchPercent > 5 {
            out.append(Finding(
                title: "Squelch is not open",
                detail: "At \(s.squelchPercent)%; a soundmodem wants it fully open.",
                fix: "Open the squelch completely. The modem's own carrier detect "
                   + "decides what is a signal; a closed squelch simply mutes the "
                   + "weak packets before the modem can try.",
                severity: .blocking, correction: .squelchOpen))
        }

        if s.mode != wantedMode {
            if modemMode.ridesOnSSB && (s.mode == .usb || s.mode == .lsb) {
                // The other sideband decodes perfectly well on its own terms.
                // AFSK inverts with the sideband and NRZI encodes transitions
                // rather than levels, so mark and space may swap and the frame
                // still comes out. What it cannot survive is disagreeing with
                // the far end, and this is also the setting AXTerm silently
                // puts back on every connect.
                out.append(Finding(
                    title: "The radio is on the other sideband",
                    detail: "Mode is \(s.mode.label); AXTerm sets \(wantedMode.label) for "
                          + "\(modemMode.title).",
                    fix: "Either sideband decodes, as long as the station you are working is "
                       + "on the same one — the tones invert with the sideband and NRZI does "
                       + "not care which is which. But while \u{201C}Set the radio for packet "
                       + "when connecting\u{201D} is on, AXTerm puts this back to "
                       + "\(wantedMode.label) at every connect, so a sideband set by hand will "
                       + "not survive a reconnect.",
                    severity: .suggestion))
            } else {
                out.append(Finding(
                    title: "The radio is in the wrong mode",
                    detail: "Mode is \(s.mode.label); \(modemMode.title) needs "
                          + "\(wantedMode.label).",
                    fix: "Switch to \(wantedMode.label) with data mode on. "
                       + (modemMode.ridesOnSSB
                          ? "300-baud HF packet is an SSB mode; in FM the tones never reach the "
                          + "demodulator at all."
                          : "1200-baud packet is FM."),
                    severity: .blocking))
            }
        }

        // Judged whatever the mode is. A narrow filter is the setting most
        // likely to be wrong at 300 bd, where the two tones are 200 Hz apart
        // and a data filter narrower than the pair simply removes one of them.
        if s.filter > 1 {
            out.append(Finding(
                title: "A narrow filter is selected",
                detail: "Filter \(s.filter) of 3.",
                fix: modemMode.ridesOnSSB
                    ? "Select FIL1, the widest. The tones are 1600 and 1800 Hz, so this mode "
                    + "needs about 1.8 kHz of passband; a narrow data filter cuts the space "
                    + "tone off and the two can no longer be told apart."
                    : "Select FIL1, the widest. 1200-baud AFSK runs about 3 kHz "
                    + "deviation and a narrow filter clips it — strong signals survive "
                    + "the clipping, marginal ones do not.",
                severity: .blocking, correction: .widestFilter))
        }

        if s.noiseReduction {
            out.append(Finding(
                title: "Noise reduction is on",
                detail: "NR is enabled.",
                fix: "Turn NR off. It is built to make speech easier for an ear and it "
                   + "smears the tone transitions a modem measures.",
                severity: .degrading, correction: .noiseReductionOff))
        }
        if s.noiseBlanker {
            out.append(Finding(
                title: "The noise blanker is on",
                detail: "NB is enabled.",
                fix: "Turn NB off. It punches holes in the audio, and a hole inside a "
                   + "frame costs the whole frame.",
                severity: .degrading, correction: .noiseBlankerOff))
        }

        if s.preamp == 0 {
            out.append(Finding(
                title: "The preamp is off",
                detail: "No preamp selected.",
                fix: modemMode.ridesOnSSB
                    ? "Worth trying P.AMP1 on a quiet HF band. Not a fault — it is the right "
                    + "choice on a crowded one — but it is free margin otherwise."
                    : "Worth trying P.AMP1 on 2 m. Not a fault — it is the right choice "
                    + "on a crowded band — but it is free margin on a quiet one.",
                severity: .suggestion))
        }

        return out.sorted { $0.severity < $1.severity }
    }

    /// The outcome of asking the radio about itself.
    ///
    /// A list of findings and an inability to read any is not the same thing,
    /// and they must never look the same. `auditReceive` used to return an
    /// empty array for both, so a dead CI-V link reported "nothing is holding
    /// receive back" — the most reassuring possible way to say "I have no
    /// idea", and one an operator could act on by buying an antenna.
    enum Result: Equatable, Sendable {
        /// We asked, and this is what the radio said.
        case checked([Finding])
        /// We could not ask, and this is why.
        case unavailable(String)

        var isAnswer: Bool {
            if case .checked = self { return true }
            return false
        }

        var findings: [Finding] {
            if case .checked(let f) = self { return f }
            return []
        }

        var summary: String {
            switch self {
            case .unavailable(let why):
                return "Could not read the radio's settings — \(why)"
            case .checked(let findings):
                return RigReceiveAudit.summary(findings)
                    ?? "Nothing in the radio's settings is holding receive back."
            }
        }
    }

    /// What is wrong now that was not wrong before.
    ///
    /// The radio belongs to the operator and they use it: somebody turns on NR
    /// for a weak voice signal and forgets, and the packet station quietly
    /// gets worse. Reporting the standing state every couple of minutes would
    /// be wallpaper; reporting the change is a warning.
    static func newFindings(from old: [Finding], to new: [Finding]) -> [Finding] {
        let known = Set(old.map(\.title))
        return new.filter { !known.contains($0.title) }
    }

    /// One line for a status row, or nil when there is nothing to say.
    static func summary(_ findings: [Finding]) -> String? {
        guard let worst = findings.map(\.severity).min() else { return nil }
        let n = findings.count
        switch worst {
        case .blocking:
            return "\(n == 1 ? "One setting is" : "\(n) settings are") costing you receive range"
        case .degrading:
            return "\(n == 1 ? "One setting is" : "\(n) settings are") making the audio harder to decode"
        case .suggestion:
            return "\(n == 1 ? "One setting" : "\(n) settings") worth trying"
        }
    }
}
