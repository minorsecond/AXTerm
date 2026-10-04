import Foundation

// Setting the radio up for packet while connected, and putting it back.
//
// Until 2026-09-30 AXTerm wrote the operator's radio at every connect and
// never undid any of it. The mode, the data input, four TX delay menus and
// CI-V Transceive all stayed the way AXTerm left them after it quit, and
// the next time the operator picked up the radio for voice it was in FM-D
// with its TX delays gone. The TNC4 has been treated better since
// 2026-09-29: the link records what the TNC held, applies the radio's own
// settings, and puts the TNC's back on disconnect. This is the same
// promise for a radio on CI-V.
//
// Everything here is pure. `CIVClient` does the reads and writes, and
// `ModemRadioLink` decides when.

/// One setting AXTerm may change while preparing the radio, and may later
/// put back.
///
/// Values are the CI-V data bytes, exactly as the radio reports them and
/// takes them, so a restore writes back what was read without interpreting
/// it.
nonisolated enum RigPrepSetting: Hashable, Sendable {
    /// Mode, filter and data mode, together: `[mode, filter, data, dataFilter]`.
    ///
    /// One setting because they are one on the radio. `06` (set mode) clears
    /// the data flag on an Icom, so a restore that put data mode back first
    /// and then the mode would lose data mode again, and one that did them
    /// in either order as separate settings could leave a radio that was in
    /// USB-D in plain USB.
    case mode
    /// A set-mode menu item (`1A 05 <item>`); the value is the bytes after
    /// the item number.
    case menuItem(Int)
    /// `11`, one byte.
    case attenuator
    /// `14 02`, two BCD bytes, 0000-0255.
    case rfGain
    /// `14 03`, two BCD bytes, 0000-0255; 0 is fully open.
    case squelch
    /// `16 40`, `00`/`01`.
    case noiseReduction
    /// `16 22`, `00`/`01`.
    case noiseBlanker
    /// `16 41`, `00`/`01`.
    case autoNotch
    /// `16 48`, `00`/`01`.
    case manualNotch
    /// `16 5D`, one byte; see `RigReceiveAudit.ToneSquelchFunction`.
    case toneSquelch

    /// A stable name for storage. Changing one strands every snapshot saved
    /// under the old name, so these do not change.
    var key: String {
        switch self {
        case .mode: return "mode"
        case .menuItem(let item): return "menu.\(item)"
        case .attenuator: return "attenuator"
        case .rfGain: return "rfGain"
        case .squelch: return "squelch"
        case .noiseReduction: return "noiseReduction"
        case .noiseBlanker: return "noiseBlanker"
        case .autoNotch: return "autoNotch"
        case .manualNotch: return "manualNotch"
        case .toneSquelch: return "toneSquelch"
        }
    }

    init?(key: String) {
        switch key {
        case "mode": self = .mode
        case "attenuator": self = .attenuator
        case "rfGain": self = .rfGain
        case "squelch": self = .squelch
        case "noiseReduction": self = .noiseReduction
        case "noiseBlanker": self = .noiseBlanker
        case "autoNotch": self = .autoNotch
        case "manualNotch": self = .manualNotch
        case "toneSquelch": self = .toneSquelch
        default:
            guard key.hasPrefix("menu."), let item = Int(key.dropFirst(5)), (0...9999).contains(item) else {
                return nil
            }
            self = .menuItem(item)
        }
    }

    /// What the operator calls it, for notices.
    var label: String {
        switch self {
        case .mode: return "mode"
        case .menuItem(let item):
            switch CIVCommand.MenuItem(rawValue: item) {
            case .txDelayHF?: return "TX delay (HF)"
            case .txDelay50M?: return "TX delay (50 MHz)"
            case .txDelay144M?: return "TX delay (144 MHz)"
            case .txDelay430M?: return "TX delay (430 MHz)"
            case .usbAFSquelch?: return "USB AF squelch"
            case .dataMod?: return "DATA MOD"
            case .usbSend?: return "USB SEND"
            case .civTransceive?: return "CI-V transceive"
            default: return String(format: "menu item %04d", item)
            }
        case .attenuator: return "attenuator"
        case .rfGain: return "RF gain"
        case .squelch: return "squelch"
        case .noiseReduction: return "noise reduction"
        case .noiseBlanker: return "noise blanker"
        case .autoNotch: return "auto notch"
        case .manualNotch: return "manual notch"
        case .toneSquelch: return "tone squelch"
        }
    }

    /// Whether `value` has the shape this setting's data takes. A stored
    /// snapshot is checked against this before anything is written from it,
    /// so a damaged one cannot send the radio a malformed command.
    func isWellFormed(_ value: [UInt8]) -> Bool {
        switch self {
        case .mode:
            return value.count == 4 && RigMode(rawValue: value[0]) != nil && value[2] <= 1
        case .menuItem:
            return !value.isEmpty && value.count <= 4
        case .attenuator:
            return value.count == 1 && Self.isBCD(value[0])
        case .rfGain, .squelch:
            return value.count == 2 && CIVBCD.meter(value).map { $0 <= 255 } == true
        case .noiseReduction, .noiseBlanker, .autoNotch, .manualNotch:
            return value.count == 1 && value[0] <= 1
        case .toneSquelch:
            return value.count == 1 && RigReceiveAudit.ToneSquelchFunction(rawValue: value[0]) != nil
        }
    }

    private static func isBCD(_ byte: UInt8) -> Bool { byte & 0x0F < 10 && byte >> 4 < 10 }

    // MARK: Frames

    /// The reads that report this setting, in order. Two for the mode: `04`
    /// has the mode and filter, `1A 06` the data flag.
    func readFrames(radio: UInt8, controller: UInt8) -> [CIVFrame] {
        switch self {
        case .mode:
            return [CIVCommand.readMode(radio: radio, controller: controller),
                    CIVCommand.readDataMode(radio: radio, controller: controller)]
        case .menuItem(let item):
            return [CIVFrame(to: radio, from: controller, command: 0x1A, subcommand: 0x05, data: CIVBCD.item(item))]
        case .attenuator: return [CIVCommand.readAttenuator(radio: radio, controller: controller)]
        case .rfGain: return [CIVCommand.readRFGain(radio: radio, controller: controller)]
        case .squelch: return [CIVCommand.readSquelchLevel(radio: radio, controller: controller)]
        case .noiseReduction: return [CIVCommand.readNoiseReduction(radio: radio, controller: controller)]
        case .noiseBlanker: return [CIVCommand.readNoiseBlanker(radio: radio, controller: controller)]
        case .autoNotch: return [CIVCommand.readAutoNotch(radio: radio, controller: controller)]
        case .manualNotch: return [CIVCommand.readManualNotch(radio: radio, controller: controller)]
        case .toneSquelch: return [CIVCommand.readToneSquelchFunction(radio: radio, controller: controller)]
        }
    }

    /// The value in the radio's replies to `readFrames`, or nil when a reply
    /// is short, malformed, or answers a different question.
    func decode(_ replies: [CIVFrame]) -> [UInt8]? {
        let reads = readFrames(radio: 0, controller: 0)
        guard replies.count == reads.count,
              zip(replies, reads).allSatisfy({ $0.command == $1.command && $0.subcommand == $1.subcommand })
        else { return nil }
        let value: [UInt8]
        switch self {
        case .mode:
            // A radio may leave the filter off a mode reply; the reference
            // guide's default is FIL1, which is what `readMode` has always
            // assumed. The data reply may likewise carry only the flag.
            let modeData = replies[0].data, dataData = replies[1].data
            guard let mode = modeData.first, let data = dataData.first else { return nil }
            let filter = modeData.count > 1 ? modeData[1] : 1
            let dataFilter = dataData.count > 1 ? dataData[1] : (data == 1 ? 1 : 0)
            value = [mode, filter, data, dataFilter]
        case .menuItem(let item):
            // The reply echoes the item number; one for another item is a
            // stale answer, not this one.
            let data = replies[0].data
            guard data.count > 2, Array(data.prefix(2)) == CIVBCD.item(item) else { return nil }
            value = Array(data.dropFirst(2))
        case .rfGain, .squelch:
            value = Array(replies[0].data.prefix(2))
        default:
            value = Array(replies[0].data.prefix(1))
        }
        return isWellFormed(value) ? value : nil
    }

    /// The writes that put `value` on the radio, in order; empty when the
    /// value is malformed, so nothing is sent.
    func writeFrames(_ value: [UInt8], radio: UInt8, controller: UInt8) -> [CIVFrame] {
        guard isWellFormed(value) else { return [] }
        switch self {
        case .mode:
            // Mode first, because it clears the data flag; then the flag.
            let data: [UInt8] = value[2] == 1 ? [0x01, value[3]] : [0x00, 0x00]
            return [CIVFrame(to: radio, from: controller, command: 0x06, subcommand: nil, data: [value[0], value[1]]),
                    CIVFrame(to: radio, from: controller, command: 0x1A, subcommand: 0x06, data: data)]
        case .menuItem(let item):
            return [CIVFrame(to: radio, from: controller, command: 0x1A, subcommand: 0x05,
                             data: CIVBCD.item(item) + value)]
        case .attenuator: return [CIVCommand.setAttenuator(value[0], radio: radio, controller: controller)]
        case .rfGain: return [CIVFrame(to: radio, from: controller, command: 0x14, subcommand: 0x02, data: value)]
        case .squelch: return [CIVFrame(to: radio, from: controller, command: 0x14, subcommand: 0x03, data: value)]
        case .noiseReduction: return [CIVFrame(to: radio, from: controller, command: 0x16, subcommand: 0x40, data: value)]
        case .noiseBlanker: return [CIVFrame(to: radio, from: controller, command: 0x16, subcommand: 0x22, data: value)]
        case .autoNotch: return [CIVFrame(to: radio, from: controller, command: 0x16, subcommand: 0x41, data: value)]
        case .manualNotch: return [CIVFrame(to: radio, from: controller, command: 0x16, subcommand: 0x48, data: value)]
        case .toneSquelch: return [CIVFrame(to: radio, from: controller, command: 0x16, subcommand: 0x5D, data: value)]
        }
    }
}

extension RigPrepSetting: Codable {
    init(from decoder: Decoder) throws {
        let key = try decoder.singleValueContainer().decode(String.self)
        guard let setting = RigPrepSetting(key: key) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown rig setting \(key)"))
        }
        self = setting
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}

/// What AXTerm changed on one radio, and what each setting was before.
///
/// Kept per radio in the app's defaults (`RigPrepStore`), written as soon as
/// a change is made, so it outlives a dropped link, an auto-reconnect and a
/// crash. Whatever is in it is still owed back to the radio.
nonisolated struct RigPrepSnapshot: Codable, Equatable, Sendable {

    struct Entry: Codable, Equatable, Sendable {
        var setting: RigPrepSetting
        /// What the radio held before AXTerm first changed it.
        var original: [UInt8]
        /// What AXTerm set it to.
        var applied: [UInt8]
    }

    /// In the order they were first changed. A restore goes in reverse.
    private(set) var entries: [Entry] = []

    init(entries: [Entry] = []) {
        for entry in entries { record(entry) }
    }

    var isEmpty: Bool { entries.isEmpty }
    var settings: [RigPrepSetting] { entries.map(\.setting) }

    func entry(for setting: RigPrepSetting) -> Entry? {
        entries.first { $0.setting == setting }
    }

    /// Note a change.
    ///
    /// A setting already here keeps its original. That is the case the
    /// snapshot exists for: after a crash or a dropped link, the radio is
    /// still in AXTerm's settings, and the next connect must not mistake
    /// them for the operator's. A change that lands back on the original
    /// leaves nothing owed, so the entry goes.
    mutating func record(_ entry: Entry) {
        guard entry.setting.isWellFormed(entry.original), entry.setting.isWellFormed(entry.applied) else { return }
        if let index = entries.firstIndex(where: { $0.setting == entry.setting }) {
            let original = entries[index].original
            if original == entry.applied {
                entries.remove(at: index)
            } else {
                entries[index].applied = entry.applied
            }
        } else if entry.original != entry.applied {
            entries.append(entry)
        }
    }

    mutating func record(contentsOf more: [Entry]) {
        for entry in more { record(entry) }
    }

    /// The snapshot without these settings.
    func removing(_ settings: Set<RigPrepSetting>) -> RigPrepSnapshot {
        var copy = self
        copy.entries.removeAll { settings.contains($0.setting) }
        return copy
    }

    // A damaged entry (a value of the wrong shape, a setting name this build
    // does not know) is dropped on the way in rather than failing the whole
    // snapshot: the rest is still owed to the radio.
    private enum CodingKeys: String, CodingKey { case entries }
    private struct LenientEntry: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decode([LenientEntry].self, forKey: .entries)
        self.init(entries: stored.compactMap(\.entry))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }
}

/// Deciding what to put back.
nonisolated enum RigPrepRestore {

    struct Plan: Equatable, Sendable {
        /// Write the original back, in this order (the reverse of how they
        /// were applied).
        var writes: [RigPrepSnapshot.Entry] = []
        /// The radio holds something other than what AXTerm set: the
        /// operator changed it during the session, and it is theirs now.
        var changedByOperator: [RigPrepSnapshot.Entry] = []
        /// Already back at the original; nothing to send.
        var alreadyBack: [RigPrepSnapshot.Entry] = []
    }

    /// Which settings to put back, given what the radio holds now.
    ///
    /// `current` has a value for each setting the radio answered for. A
    /// setting it did not answer for is put back anyway: an unanswered read
    /// says nothing about the operator, and leaving AXTerm's value behind
    /// is the failure this exists to prevent. The write itself will fail if
    /// the radio is really gone, and a failed write stays owed.
    static func plan(_ snapshot: RigPrepSnapshot, current: [RigPrepSetting: [UInt8]]) -> Plan {
        var plan = Plan()
        for entry in snapshot.entries.reversed() {
            switch current[entry.setting] {
            case .none:
                plan.writes.append(entry)
            case .some(let now) where now == entry.applied:
                plan.writes.append(entry)
            case .some(let now) where now == entry.original:
                plan.alreadyBack.append(entry)
            case .some:
                plan.changedByOperator.append(entry)
            }
        }
        return plan
    }

    struct Outcome: Equatable, Sendable {
        var restored: [RigPrepSnapshot.Entry] = []
        var changedByOperator: [RigPrepSnapshot.Entry] = []
        var alreadyBack: [RigPrepSnapshot.Entry] = []
        /// The radio refused or did not answer the write.
        var failed: [RigPrepSnapshot.Entry] = []
        /// Out of time before this one was tried (the app was quitting).
        var notAttempted: [RigPrepSnapshot.Entry] = []
    }

    /// What is still owed after a restore: the failures and whatever was
    /// never reached, to try again at the next disconnect.
    static func remaining(_ snapshot: RigPrepSnapshot, after outcome: Outcome) -> RigPrepSnapshot {
        let settled = Set((outcome.restored + outcome.changedByOperator + outcome.alreadyBack).map(\.setting))
        return snapshot.removing(settled)
    }

    /// One line for the console, or nil when there was nothing to put back.
    static func notice(_ outcome: Outcome) -> String? {
        var parts: [String] = []
        if !outcome.restored.isEmpty {
            parts.append("Put the radio back as it was: " + list(outcome.restored) + ".")
        }
        if !outcome.changedByOperator.isEmpty {
            parts.append("Left " + list(outcome.changedByOperator)
                         + " as you set \(outcome.changedByOperator.count == 1 ? "it" : "them") during the session.")
        }
        let owed = outcome.failed + outcome.notAttempted
        if !owed.isEmpty {
            parts.append("Could not put back " + list(owed)
                         + "; AXTerm will try again the next time this radio disconnects.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func list(_ entries: [RigPrepSnapshot.Entry]) -> String {
        var seen: [String] = []
        for label in entries.map(\.setting.label) where !seen.contains(label) { seen.append(label) }
        return seen.joined(separator: ", ")
    }
}

/// How a correction from the receive audit maps onto a setting and a value.
nonisolated enum RigPrep {

    /// The receive settings cleared on connect, in order, whose right value
    /// for packet is a fact. The preamp is not among them: whether it helps
    /// is a judgment about the band. The filter is set with the mode.
    static func receiveClears(toneSquelchFunction: Bool) -> [RigReceiveAudit.Correction] {
        var out: [RigReceiveAudit.Correction] = [
            .attenuatorOff, .rfGainFull, .squelchOpen, .noiseReductionOff, .noiseBlankerOff,
            .autoNotchOff, .manualNotchOff,
        ]
        if toneSquelchFunction { out.append(.toneSquelchReceiveOff) }
        return out
    }

    static func setting(for correction: RigReceiveAudit.Correction) -> RigPrepSetting {
        switch correction {
        case .attenuatorOff: return .attenuator
        case .rfGainFull: return .rfGain
        case .squelchOpen: return .squelch
        case .noiseReductionOff: return .noiseReduction
        case .noiseBlankerOff: return .noiseBlanker
        case .widestFilter: return .mode
        case .autoNotchOff: return .autoNotch
        case .manualNotchOff: return .manualNotch
        case .toneSquelchReceiveOff: return .toneSquelch
        }
    }

    /// The value the correction leaves, given what the radio holds now; nil
    /// when the current value is not one this can judge.
    static func target(for correction: RigReceiveAudit.Correction, current: [UInt8]) -> [UInt8]? {
        let setting = setting(for: correction)
        guard setting.isWellFormed(current) else { return nil }
        switch correction {
        case .attenuatorOff: return [0x00]
        case .rfGainFull: return CIVBCD.meterBytes(255)
        case .squelchOpen: return CIVBCD.meterBytes(0)
        case .noiseReductionOff, .noiseBlankerOff, .autoNotchOff, .manualNotchOff: return [0x00]
        case .widestFilter:
            // FIL1 in the same mode, and data mode as it was: `06` clears the
            // flag, so the flag is written back after it.
            return [current[0], 0x01, current[2], current[2] == 1 ? 0x01 : 0x00]
        case .toneSquelchReceiveOff:
            guard let function = RigReceiveAudit.ToneSquelchFunction(rawValue: current[0]) else { return nil }
            return [function.withoutReceiveDecoder.rawValue]
        }
    }

    /// "auto notch off", "tone squelch TSQL to TONE": one change, for the
    /// connect notice.
    static func describe(_ setting: RigPrepSetting, from old: [UInt8], to new: [UInt8]) -> String {
        switch setting {
        case .attenuator: return "attenuator off"
        case .rfGain: return "RF gain full"
        case .squelch: return "squelch open"
        case .noiseReduction: return "noise reduction off"
        case .noiseBlanker: return "noise blanker off"
        case .autoNotch: return "auto notch off"
        case .manualNotch: return "manual notch off"
        case .toneSquelch:
            let was = old.first.flatMap(RigReceiveAudit.ToneSquelchFunction.init(rawValue:))?.label ?? "on"
            let now = new.first.flatMap(RigReceiveAudit.ToneSquelchFunction.init(rawValue:))?.label ?? "off"
            return "tone squelch \(was) to \(now)"
        case .mode, .menuItem: return "\(setting.label) changed"
        }
    }

    /// Whether the radio is one whose tone squelch function is confirmed at
    /// `16 5D`. The IC-705 answers from `A4` by default, and a LAN login
    /// names it; either is enough. Other Icoms split the function across
    /// `16 42`, `16 43` and `16 4B` or put it elsewhere, and a read there
    /// would be judging a command whose meaning on that radio is uncertain.
    static func confirmsToneSquelchFunction(model: String?, address: UInt8) -> Bool {
        address == CIVCommand.ic705 || (model?.contains("705") ?? false)
    }
}

/// Where each radio's snapshot lives between sessions.
nonisolated struct RigPrepStore: @unchecked Sendable {
    let defaults: UserDefaults
    static let keyPrefix = "rigPrep.v1."

    init(defaults: UserDefaults = AppEnvironment.owedToRadioDefaults) {
        self.defaults = defaults
    }

    static func key(_ radio: RadioID) -> String { keyPrefix + radio.rawValue }

    /// Nil when nothing is owed, or when what is stored cannot be read.
    func load(_ radio: RadioID) -> RigPrepSnapshot? {
        guard let data = defaults.data(forKey: Self.key(radio)),
              let snapshot = try? JSONDecoder().decode(RigPrepSnapshot.self, from: data),
              !snapshot.isEmpty else { return nil }
        return snapshot
    }

    /// Store it, or forget the radio when nothing is owed.
    func save(_ snapshot: RigPrepSnapshot, for radio: RadioID) {
        guard !snapshot.isEmpty, let data = try? JSONEncoder().encode(snapshot) else {
            defaults.removeObject(forKey: Self.key(radio))
            return
        }
        defaults.set(data, forKey: Self.key(radio))
    }
}
