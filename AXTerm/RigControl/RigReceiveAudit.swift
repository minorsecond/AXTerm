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
        /// Automatic notch filter (ANF), `16 41`.
        var autoNotch: Bool = false
        /// Manual notch, `16 48`.
        var manualNotch: Bool = false
        /// The tone squelch function, `16 5D`. Read only where that command
        /// is confirmed for the radio (see `CIVCommand.readToneSquelchFunction`);
        /// elsewhere it stays `.off`, which judges nothing.
        var toneSquelch: ToneSquelchFunction = .off
        /// Whether the radio answered anything at all. A settings struct full
        /// of benign defaults because every read timed out must not be judged
        /// as a healthy radio.
        var answered: Bool = true
    }

    /// What the radio does with CTCSS tones and DTCS codes, as the IC-705
    /// reports it in `16 5D`.
    ///
    /// Values from the IC-705 CI-V Reference Guide (Icom, 2020 edition,
    /// command table p. 4): 00 OFF, 01 TONE, 02 TSQL, 03 DTCS, 06 DTCS(T),
    /// 07 TONE(T)/DTCS(R), 08 DTCS(T)/TSQL(R), 09 TONE(T)/TSQL(R). wfview's
    /// IC-705 rig file lists the same command as "Tone Squelch Type", 0-9.
    ///
    /// "(T)" is transmit only and "(R)" receive only; TSQL and DTCS on their
    /// own do both, sending the tone and muting everything that lacks it.
    /// Only the receive half is a receive problem. A repeater tone on
    /// transmit changes nothing about what the modem hears, so the fix keeps
    /// whatever the radio sends and drops only the decoder.
    enum ToneSquelchFunction: UInt8, Sendable, Equatable {
        case off = 0x00
        case tone = 0x01
        case tsql = 0x02
        case dtcs = 0x03
        case dtcsTransmit = 0x06
        case toneTransmitDTCSReceive = 0x07
        case dtcsTransmitTSQLReceive = 0x08
        case toneTransmitTSQLReceive = 0x09

        /// Whether the receiver stays muted for a station that does not send
        /// the right tone or code.
        var mutesReceive: Bool {
            switch self {
            case .off, .tone, .dtcsTransmit: return false
            case .tsql, .dtcs, .toneTransmitDTCSReceive, .dtcsTransmitTSQLReceive,
                 .toneTransmitTSQLReceive: return true
            }
        }

        /// The same transmit behavior with the receive decoder off.
        var withoutReceiveDecoder: ToneSquelchFunction {
            switch self {
            case .off, .tone, .dtcsTransmit: return self
            case .tsql, .toneTransmitDTCSReceive, .toneTransmitTSQLReceive: return .tone
            case .dtcs, .dtcsTransmitTSQLReceive: return .dtcsTransmit
            }
        }

        /// The radio's own name for the setting.
        var label: String {
            switch self {
            case .off: return "OFF"
            case .tone: return "TONE"
            case .tsql: return "TSQL"
            case .dtcs: return "DTCS"
            case .dtcsTransmit: return "DTCS(T)"
            case .toneTransmitDTCSReceive: return "TONE(T)/DTCS(R)"
            case .dtcsTransmitTSQLReceive: return "DTCS(T)/TSQL(R)"
            case .toneTransmitTSQLReceive: return "TONE(T)/TSQL(R)"
            }
        }
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
    /// USB on purpose, and whether a preamp helps is a judgment about the
    /// band rather than a fault to be repaired.
    enum Correction: Equatable, Sendable {
        case attenuatorOff
        case rfGainFull
        case squelchOpen
        case noiseReductionOff
        case noiseBlankerOff
        case widestFilter
        case autoNotchOff
        case manualNotchOff
        /// Tone squelch off for receive, keeping any tone the radio sends.
        case toneSquelchReceiveOff
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
        /// value is the operator's judgment rather than a fact.
        var correction: Correction?
    }

    /// Everything worth saying about these settings, worst first.
    ///
    /// `modemMode` is what the modem is set to, and every judgment about the
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
                   + "must reach before the receiver hears it at all. It is easy to leave "
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
                       + "on the same one: the tones invert with the sideband and NRZI does "
                       + "not care which is which. But while \u{201C}Set up the radio for packet "
                       + "while connected\u{201D} is on, AXTerm sets \(wantedMode.label) at every "
                       + "connect, so a sideband set by hand lasts only until the next one.",
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
                    + "deviation and a narrow filter clips it. Strong signals survive "
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

        // Found live on 2026-09-30: an IC-705 on a busy 144.390 decoded about
        // one APRS frame a minute with the notch on by accident, and fourteen
        // in three minutes with it off, while Direwolf on the same audio
        // decoded seventeen. Nothing in this audit looked at the notch.
        if s.autoNotch {
            out.append(Finding(
                title: "The auto notch is on",
                detail: "ANF is enabled.",
                fix: "Turn the auto notch off. It hunts for steady tones and removes them, "
                   + "and AFSK is two steady tones. On the IC-705 it cut decoding on a "
                   + "busy APRS channel to a handful of frames.",
                severity: .blocking, correction: .autoNotchOff))
        }
        if s.manualNotch {
            out.append(Finding(
                title: "The manual notch is on",
                detail: "The manual notch is enabled.",
                fix: "Turn the manual notch off. It cuts a slot out of the audio, and "
                   + "wherever it sits near \(modemMode.ridesOnSSB ? "1600 or 1800" : "1200 or 2200") Hz "
                   + "it takes one of the two tones with it.",
                severity: .degrading, correction: .manualNotchOff))
        }
        if s.toneSquelch.mutesReceive {
            out.append(Finding(
                title: "Tone squelch is on",
                detail: "Set to \(s.toneSquelch.label).",
                fix: "Turn the receive tone squelch off. It keeps the audio muted for every "
                   + "station that does not send the matching tone, and packet stations "
                   + "almost never do. AXTerm leaves any tone you transmit alone.",
                severity: .blocking, correction: .toneSquelchReceiveOff))
        }

        if s.preamp == 0 {
            out.append(Finding(
                title: "The preamp is off",
                detail: "No preamp selected.",
                fix: modemMode.ridesOnSSB
                    ? "Worth trying P.AMP1 on a quiet HF band. Not a fault, since it is the right "
                    + "choice on a crowded one, but it is free margin otherwise."
                    : "Worth trying P.AMP1 on 2 m. Not a fault, since it is the right choice "
                    + "on a crowded band, but it is free margin on a quiet one.",
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
                return "Could not read the radio's settings: \(why)"
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

    /// Receive settings that went wrong during the session, held until they
    /// are fixed or put right by hand.
    ///
    /// `newFindings` compares two audits; this remembers what it found, so
    /// the radio page can offer a fix for a change made minutes ago and
    /// stop offering it once the setting is back. A change is announced
    /// once, when it first appears, and never again while it stands.
    struct DriftWatch: Equatable, Sendable {
        /// The audit everything is compared against; nil before the first.
        private(set) var baseline: [Finding]?
        /// What changed and is still wrong, oldest first.
        private(set) var pending: [Finding] = []

        init() {}

        /// Take a fresh audit. Returns what is newly wrong, to announce.
        ///
        /// The first audit only sets the baseline: what the radio was like
        /// when AXTerm connected is not a change during the session.
        mutating func observe(_ now: [Finding]) -> [Finding] {
            guard let before = baseline else {
                baseline = now
                return []
            }
            let new = RigReceiveAudit.newFindings(from: before, to: now)
            baseline = now
            let standing = Set(now.map(\.title))
            pending = pending.filter { standing.contains($0.title) }
            for finding in new where !pending.contains(where: { $0.title == finding.title }) {
                pending.append(finding)
            }
            return new
        }

        /// These were fixed; stop offering them.
        mutating func resolve(_ titles: Set<String>) {
            pending.removeAll { titles.contains($0.title) }
            baseline = baseline?.filter { !titles.contains($0.title) }
        }
    }

    /// What the link knows about the radio's receive settings, for the
    /// status surfaces: the latest audit, and what changed since connecting.
    struct Report: Equatable, Sendable {
        var findings: [Finding] = []
        var drift: [Finding] = []
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
