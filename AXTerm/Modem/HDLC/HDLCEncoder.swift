import Foundation

/// AX.25 frames in, NRZI line levels out, one bit at a time.
///
/// A transmission is a preamble of flags long enough for the receiver's
/// transmitter-to-receiver switch (TXDELAY), the frames with their FCS, two
/// flags between frames sent back to back, and a tail of flags (TXTAIL) so
/// the last frame's closing flag is not clipped by the transmitter dropping.
/// Frames may be appended until the tail has started; after that they wait
/// for the next transmission.
nonisolated struct HDLCEncoder: Sendable {

    enum Phase: Equatable, Sendable { case preamble, frame, gap, tail, done }

    let baud: Double
    let preambleFlags: Int
    let tailFlags: Int
    let interFrameFlags: Int

    private(set) var phase: Phase = .preamble
    private var pending: [[UInt8]] = []
    private var flagsRemaining: Int
    private var flagBitIndex = 8          // 8 = no flag in progress
    private var current: [UInt8] = []
    private var byteIndex = 0
    private var bitIndex = 0
    private var onesRun = 0
    private var stuffPending = false
    private var nrzi = NRZIEncoder()

    /// Flags for a duration at a baud rate — at least one.
    static func flagCount(milliseconds: Int, baud: Double) -> Int {
        max(1, Int((Double(max(0, milliseconds)) * baud / 8000.0).rounded(.up)))
    }

    init(baud: Double, txDelayMs: Int, txTailMs: Int, interFrameFlags: Int = 2) {
        self.baud = baud
        self.preambleFlags = Self.flagCount(milliseconds: txDelayMs, baud: baud)
        self.tailFlags = Self.flagCount(milliseconds: txTailMs, baud: baud)
        self.interFrameFlags = max(1, interFrameFlags)
        self.flagsRemaining = preambleFlags
    }

    var hasStartedTail: Bool { phase == .tail || phase == .done }
    var isDone: Bool { phase == .done }
    var queuedFrames: Int { pending.count + (phase == .frame ? 1 : 0) }

    /// Queue a frame (without FCS) for this transmission. Refused once the
    /// tail has started — the caller starts a new transmission instead.
    @discardableResult
    mutating func append(frame: Data) -> Bool {
        guard !hasStartedTail else { return false }
        var bytes = [UInt8](frame)
        let (lo, hi) = CRC16X25.fcsBytes(for: bytes)
        bytes.append(lo)
        bytes.append(hi)
        pending.append(bytes)
        return true
    }

    /// The next line level, or nil when the transmission is complete.
    mutating func nextBit() -> Bool? {
        guard let raw = nextRawBit() else { return nil }
        return nrzi.encode(bit: raw)
    }

    /// The next data bit before NRZI — flags, stuffed data, flags.
    mutating func nextRawBit() -> Bool? {
        while true {
            switch phase {
            case .done:
                return nil

            case .preamble, .gap, .tail:
                if flagBitIndex < 8 {
                    let bit = (0x7E >> flagBitIndex) & 1 == 1
                    flagBitIndex += 1
                    return bit
                }
                if flagsRemaining > 0 {
                    flagsRemaining -= 1
                    flagBitIndex = 0
                    continue
                }
                // This run of flags is over.
                switch phase {
                case .tail:
                    phase = .done
                default:
                    if let next = pending.first {
                        pending.removeFirst()
                        startFrame(next)
                    } else {
                        phase = .tail
                        flagsRemaining = tailFlags
                    }
                }

            case .frame:
                if stuffPending {
                    stuffPending = false
                    onesRun = 0
                    return false
                }
                if byteIndex >= current.count {
                    // Frame finished. More frames: a short gap; otherwise the tail.
                    if pending.isEmpty {
                        phase = .tail
                        flagsRemaining = tailFlags
                    } else {
                        phase = .gap
                        flagsRemaining = interFrameFlags
                    }
                    continue
                }
                let bit = (current[byteIndex] >> bitIndex) & 1 == 1
                bitIndex += 1
                if bitIndex == 8 { bitIndex = 0; byteIndex += 1 }
                if bit {
                    onesRun += 1
                    if onesRun == 5 { stuffPending = true }
                } else {
                    onesRun = 0
                }
                return bit
            }
        }
    }

    private mutating func startFrame(_ bytes: [UInt8]) {
        phase = .frame
        current = bytes
        byteIndex = 0
        bitIndex = 0
        onesRun = 0
        stuffPending = false
    }
}
