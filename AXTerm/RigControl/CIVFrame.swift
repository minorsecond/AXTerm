import Foundation

/// One Icom CI-V frame: `FE FE <to> <from> <cmd> [sub] [data…] FD`.
///
/// CI-V is a bus. Frames from the radio are addressed to the controller
/// (`E0`) or broadcast (`00`, "transceive"); with echo-back on, our own
/// frames come back addressed to the radio. `OK` (`FB`) and `NG` (`FA`)
/// replies carry no command byte, so a reply can only be matched to its
/// request by order — which is why `CIVClient` keeps one request in flight.
nonisolated struct CIVFrame: Equatable, Sendable {
    static let preamble: UInt8 = 0xFE
    static let terminator: UInt8 = 0xFD
    static let ok: UInt8 = 0xFB
    static let ng: UInt8 = 0xFA
    static let broadcast: UInt8 = 0x00
    static let controller: UInt8 = 0xE0

    var to: UInt8
    var from: UInt8
    var command: UInt8
    var subcommand: UInt8?
    var data: [UInt8]

    init(to: UInt8, from: UInt8, command: UInt8, subcommand: UInt8? = nil, data: [UInt8] = []) {
        self.to = to
        self.from = from
        self.command = command
        self.subcommand = subcommand
        self.data = data
    }

    var isOK: Bool { command == Self.ok }
    var isNG: Bool { command == Self.ng }

    func encoded() -> Data {
        var bytes: [UInt8] = [Self.preamble, Self.preamble, to, from, command]
        if let subcommand { bytes.append(subcommand) }
        bytes.append(contentsOf: data)
        bytes.append(Self.terminator)
        return Data(bytes)
    }

    /// The bytes after the command, with `sub` folded back in when the
    /// caller does not know whether the command has a subcommand.
    var body: [UInt8] {
        if let subcommand { return [subcommand] + data }
        return data
    }

    /// Parse one complete frame's bytes (`FE FE … FD`), or nil.
    ///
    /// `subcommandLength` says how many bytes after the command belong to
    /// the subcommand for that command — CI-V has no in-band marker.
    static func parse(_ bytes: [UInt8], subcommandLength: (UInt8) -> Int = CIVCommand.subcommandLength) -> CIVFrame? {
        guard bytes.count >= 5, bytes[0] == preamble, bytes[1] == preamble, bytes.last == terminator else { return nil }
        // Extra preambles are legal padding (`FE FE FE FE …`).
        var index = 2
        while index < bytes.count - 1, bytes[index] == preamble { index += 1 }
        guard bytes.count - index >= 4 else { return nil }   // to, from, cmd, FD
        let to = bytes[index], from = bytes[index + 1], command = bytes[index + 2]
        var rest = Array(bytes[(index + 3)..<(bytes.count - 1)])
        var subcommand: UInt8?
        if command != ok, command != ng, subcommandLength(command) == 1, !rest.isEmpty {
            subcommand = rest.removeFirst()
        }
        return CIVFrame(to: to, from: from, command: command, subcommand: subcommand, data: rest)
    }
}

/// Assembles frames out of a byte stream: garbage before a preamble is
/// dropped, a frame may arrive across several reads.
nonisolated struct CIVFrameParser: Sendable {
    private var buffer: [UInt8] = []

    init() {}

    mutating func feed(_ chunk: Data) -> [CIVFrame] {
        buffer.append(contentsOf: chunk)
        var frames: [CIVFrame] = []
        while true {
            // Resync: drop anything before "FE FE".
            guard let start = buffer.indices.first(where: { $0 + 1 < buffer.count && buffer[$0] == CIVFrame.preamble && buffer[$0 + 1] == CIVFrame.preamble }) else {
                // Keep a trailing lone FE in case its partner is in the next read.
                if buffer.last == CIVFrame.preamble { buffer = [CIVFrame.preamble] } else { buffer.removeAll() }
                return frames
            }
            if start > 0 { buffer.removeFirst(start) }
            guard let end = buffer.firstIndex(of: CIVFrame.terminator) else { return frames }
            let span = Array(buffer[0...end])
            buffer.removeFirst(end + 1)
            // Frame from the LAST preamble pair in the span, not the first.
            //
            // A CI-V frame is the bytes between a preamble pair and the next
            // terminator, which is only true while every frame arrives whole.
            // The IC-705's spectrum scope breaks that: its waveform payload is
            // raw binary, so a scope frame whose tail is lost — routine over
            // Wi-Fi, where these arrive by the hundred — leaves a headless
            // `FE FE E0 A4 27 00 …` with no terminator of its own. Framing on
            // the first preamble then runs that wreck all the way to the *next*
            // frame's terminator and swallows it whole. What it swallows is
            // whatever we were waiting on, and over the WLAN that is usually
            // the PTT acknowledgement: the transmitter never keys and the radio
            // looks, from here, like it is ignoring CI-V.
            //
            // The frame that owns this terminator begins at the last preamble
            // pair before it, so start there. Real command frames cannot
            // contain `FE` in their data — CI-V reserves it — so this only ever
            // discards junk.
            let candidate = Self.lastFrameStart(in: span).map { Array(span[$0...]) } ?? span
            if let frame = CIVFrame.parse(candidate) { frames.append(frame) }
        }
    }

    mutating func reset() { buffer.removeAll() }

    /// The index of the last `FE FE` in `bytes`, which is where the frame
    /// ending at `bytes`'s terminator begins.
    private static func lastFrameStart(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2 else { return nil }
        var index = bytes.count - 2
        while index >= 0 {
            if bytes[index] == CIVFrame.preamble, bytes[index + 1] == CIVFrame.preamble { return index }
            index -= 1
        }
        return nil
    }
}

/// CI-V's binary-coded decimal conventions.
nonisolated enum CIVBCD {

    /// Frequency as five BCD bytes, least significant pair first:
    /// 144.390 MHz → `00 00 39 44 01`.
    static func frequencyBytes(hz: Int) -> [UInt8] {
        var value = max(0, hz)
        var bytes: [UInt8] = []
        for _ in 0..<5 {
            let low = value % 10; value /= 10
            let high = value % 10; value /= 10
            bytes.append(UInt8(high << 4 | low))
        }
        return bytes
    }

    static func frequencyHz(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 5 else { return nil }
        var hz = 0
        var scale = 1
        for byte in bytes.prefix(5) {
            let low = Int(byte & 0x0F), high = Int(byte >> 4)
            guard low < 10, high < 10 else { return nil }
            hz += low * scale; scale *= 10
            hz += high * scale; scale *= 10
        }
        return hz
    }

    /// Two BCD bytes, most significant first: `01 20` → 120 (meters, levels 0…255).
    static func meter(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2 else { return nil }
        return digits(bytes[0]).map { $0 * 100 } .flatMap { hundreds in digits(bytes[1]).map { hundreds + $0 } }
    }

    static func meterBytes(_ value: Int) -> [UInt8] {
        let v = max(0, min(255, value))
        return [UInt8(v / 100), UInt8(((v % 100) / 10) << 4 | (v % 10))]
    }

    /// A four-digit menu item number as two BCD bytes: 131 → `01 31`.
    static func item(_ number: Int) -> [UInt8] {
        let n = max(0, min(9999, number))
        return [UInt8((n / 1000) << 4 | (n / 100) % 10), UInt8(((n / 10) % 10) << 4 | n % 10)]
    }

    private static func digits(_ byte: UInt8) -> Int? {
        let low = Int(byte & 0x0F), high = Int(byte >> 4)
        guard low < 10, high < 10 else { return nil }
        return high * 10 + low
    }
}

/// Which inbound frames matter to us.
nonisolated enum CIVFilter {
    /// Addressed to this controller, or broadcast (transceive).
    static func isForUs(_ frame: CIVFrame, controller: UInt8 = CIVFrame.controller) -> Bool {
        frame.to == controller || frame.to == CIVFrame.broadcast
    }
    /// Our own command coming back with echo-back on: addressed to the radio.
    static func isEcho(_ frame: CIVFrame, radio: UInt8) -> Bool {
        frame.to == radio
    }
}

/// Operating modes as CI-V numbers them.
nonisolated enum RigMode: UInt8, Codable, CaseIterable, Sendable {
    case lsb = 0x00, usb = 0x01, am = 0x02, cw = 0x03, rtty = 0x04, fm = 0x05, wfm = 0x06
    case cwReverse = 0x07, rttyReverse = 0x08, dv = 0x17

    var label: String {
        switch self {
        case .lsb: return "LSB"
        case .usb: return "USB"
        case .am: return "AM"
        case .cw: return "CW"
        case .rtty: return "RTTY"
        case .fm: return "FM"
        case .wfm: return "WFM"
        case .cwReverse: return "CW-R"
        case .rttyReverse: return "RTTY-R"
        case .dv: return "DV"
        }
    }
}

/// What the radio last told us about itself.
nonisolated struct RigStatus: Equatable, Sendable {
    var frequencyHz: Int?
    var mode: RigMode?
    var filter: UInt8?
    var dataMode: Bool?
    var squelchOpen: Bool?
    var sMeter: Int?
    var ptt = false
    var updatedAt: Date?

    init() {}

    /// "FM-D", "USB", … as the radio's own display would say it.
    var modeLabel: String? {
        guard let mode else { return nil }
        return (dataMode ?? false) ? "\(mode.label)-D" : mode.label
    }

    var frequencyLabel: String? {
        guard let hz = frequencyHz else { return nil }
        return String(format: "%.3f MHz", Double(hz) / 1_000_000)
    }
}

/// CI-V addresses of radios worth naming.
nonisolated enum CIVKnownRadios {
    static func model(forAddress address: UInt8) -> String? {
        switch address {
        case 0xA4: return "IC-705"
        case 0x94: return "IC-7300"
        case 0x98: return "IC-9700"
        case 0xA2: return "IC-7610"
        case 0x88: return "IC-7100"
        case 0x8E: return "IC-7410"
        case 0x76: return "IC-7200"
        case 0x70: return "IC-7000"
        default: return nil
        }
    }

    static func describe(_ address: UInt8) -> String {
        let hex = String(format: "%02X", address)
        return model(forAddress: address).map { "\($0) (\(hex))" } ?? "radio \(hex)"
    }
}
