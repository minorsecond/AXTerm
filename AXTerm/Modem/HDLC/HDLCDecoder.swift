import Foundation

/// Bits in, AX.25 frames out.
///
/// One instance per slicer. Bits arrive already NRZI-decoded, least
/// significant first. The decoder hunts for the flag `0x7E`, removes the zero
/// a transmitter stuffs after five consecutive ones, treats seven or more
/// ones as an abort, and hands a frame up only when it ends on a flag at a
/// byte boundary with a good FCS. Everything else is counted, not reported:
/// on a busy channel most of what a slicer sees between frames is noise
/// shaped like bits, and calling each fragment a malformed frame would bury
/// the real ones.
nonisolated struct HDLCDecoder: Sendable {

    struct Limits: Sendable, Equatable {
        /// Destination, source, control and the two FCS bytes: the shortest
        /// frame that means anything.
        var minFrameBytes = 17
        /// AX.25's nominal maximum is 332; AXTerm's own paclen and AXDP
        /// payloads and several TNCs exceed 256, so the default is generous.
        var maxFrameBytes = 1024
        init(minFrameBytes: Int = 17, maxFrameBytes: Int = 1024) {
            self.minFrameBytes = minFrameBytes
            self.maxFrameBytes = maxFrameBytes
        }
    }

    enum Event: Equatable, Sendable {
        case none
        /// A flag went by with nothing before it worth reporting.
        case flag
        /// A frame with a good FCS, FCS stripped.
        case frame(Data)
        /// Byte-aligned, in bounds, wrong FCS — the one kind of failure a
        /// tuner wants to see counted.
        case fcsError(length: Int)
        /// Seven or more ones: the transmitter gave up on this frame.
        case abort
        /// More bytes than `Limits.maxFrameBytes` without a flag.
        case tooLong
    }

    /// What the slicer is hearing, for carrier detect: flags are a station
    /// keyed up, in-frame is data, idle is nothing recognisable.
    enum Activity: Equatable, Sendable { case idle, flags, inFrame }

    let limits: Limits
    private(set) var activity: Activity = .idle

    /// Counters for telemetry; the events above are the ones worth acting on.
    private(set) var discardedFragments: Int = 0

    private var shift: UInt8 = 0
    private var bitCount = 0
    private var ones = 0
    private var buffer: [UInt8] = []
    private var synchronised = false

    init(limits: Limits = Limits()) {
        self.limits = limits
        buffer.reserveCapacity(limits.maxFrameBytes + 2)
    }

    mutating func push(bit: Bool) -> Event {
        if bit {
            ones += 1
            if ones >= 7 {
                // Abort. Keep counting ones so a long mark tone stays one
                // abort rather than one per bit.
                let hadData = synchronised && !buffer.isEmpty
                if ones == 7 { resetFrame(); activity = .idle }
                return hadData && ones == 7 ? .abort : .none
            }
            shiftIn(true)
            return .none
        }

        // A zero.
        switch ones {
        case 5:
            // The stuffed zero: not data, not a flag. Drop it.
            ones = 0
            return .none
        case 6:
            ones = 0
            return completeFlag()
        default:
            ones = 0
            shiftIn(false)
            return .none
        }
    }

    mutating func reset() {
        resetFrame()
        ones = 0
        activity = .idle
    }

    // MARK: - Internals

    private mutating func shiftIn(_ bit: Bool) {
        shift = (shift >> 1) | (bit ? 0x80 : 0)
        bitCount += 1
        guard bitCount == 8 else { return }
        bitCount = 0
        guard synchronised else { shift = 0; return }
        buffer.append(shift)
        shift = 0
        if buffer.count > limits.maxFrameBytes {
            // Runaway: nothing this long is a frame. Hunt for the next flag.
            resetFrame()
            activity = .idle
            discardedFragments += 1
            // The caller learns once; further bytes are silent until a flag.
            tooLongPending = true
        } else if activity != .inFrame {
            activity = .inFrame
        }
    }

    private var tooLongPending = false

    private mutating func completeFlag() -> Event {
        // The flag's own seven bits (0111111) were shifted in before we knew.
        // A frame that ended on a byte boundary leaves exactly those seven
        // pending; anything else was misaligned and cannot have a good FCS.
        let aligned = bitCount == 7
        let bytes = buffer
        let wasTooLong = tooLongPending
        tooLongPending = false
        resetFrame()
        synchronised = true
        activity = .flags

        if wasTooLong { return .tooLong }
        guard !bytes.isEmpty else { return .flag }
        guard aligned, bytes.count >= limits.minFrameBytes, bytes.count <= limits.maxFrameBytes else {
            discardedFragments += 1
            return .flag
        }
        if CRC16X25.verify(frameWithFCS: bytes) {
            return .frame(Data(bytes.dropLast(2)))
        }
        return .fcsError(length: bytes.count)
    }

    private mutating func resetFrame() {
        buffer.removeAll(keepingCapacity: true)
        shift = 0
        bitCount = 0
        synchronised = false
    }
}
