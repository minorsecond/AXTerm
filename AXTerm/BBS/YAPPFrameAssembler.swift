//
//  YAPPFrameAssembler.swift
//  AXTerm
//
//  Cuts a connected session's byte stream back into whole YAPP frames.
//

import Foundation

/// Reassembles YAPP frames from the byte stream a session delivers.
///
/// AX.25 carries bytes, not frames. A YAPP data block is up to 254 bytes and
/// the link's paclen is often 128, so one block routinely arrives as two
/// I-frames, and a short ACK can share an I-frame with whatever the far end
/// typed next. `YAPPProtocol` parses one complete frame per call and NAKs
/// anything short, so feeding it I-frame payloads as they come would NAK
/// every block on an ordinary link. This sits in front of it.
///
/// Frame lengths follow the encoding `YAPPProtocol` itself produces:
///
/// | Lead byte | Frame | Length |
/// |---|---|---|
/// | SOH 01 / SOH 02 | send init / receive init | 2 |
/// | SOH n | header | 2 + n |
/// | STX hi lo | data block | 3 + len + 1 (checksum) |
/// | ETX 01 | end of file | 2 |
/// | EOT, ACK, NAK, CAN | | 1 |
///
/// Anything else is text the far end typed, handed back separately so a
/// caller whose software does not speak YAPP can still type `A` to stop.
nonisolated struct YAPPFrameAssembler: Equatable, Sendable {

    enum Piece: Equatable, Sendable {
        case frame(Data)
        case text(Data)
        /// A data block claiming more than `maxBlockBytes`. Nothing this app
        /// sends is that large, and waiting for 64 KB that will never come
        /// would hang the transfer, so the buffer is dropped and the caller
        /// told to give up.
        case malformed
    }

    /// Four times the 250 bytes a block normally carries, which leaves room
    /// for other YAPP implementations without buffering a block nobody sends.
    static let maxBlockBytes = 1024

    private(set) var buffered = Data()

    var isEmpty: Bool { buffered.isEmpty }

    mutating func push(_ data: Data) -> [Piece] {
        buffered.append(data)
        var pieces: [Piece] = []

        while let lead = buffered.first {
            if let control = YAPPControlChar(rawValue: lead) {
                guard let length = frameLength(for: control) else { break }
                if length < 0 {
                    buffered.removeAll()
                    pieces.append(.malformed)
                    break
                }
                guard buffered.count >= length else { break }
                pieces.append(.frame(Data(buffered.prefix(length))))
                buffered = Data(buffered.dropFirst(length))
            } else {
                // A run of text, up to the next byte that could open a frame.
                let end = buffered.firstIndex { YAPPControlChar(rawValue: $0) != nil }
                    ?? buffered.endIndex
                pieces.append(.text(Data(buffered[buffered.startIndex..<end])))
                buffered = Data(buffered[end...])
            }
        }
        return pieces
    }

    mutating func reset() { buffered.removeAll() }

    /// Bytes this frame needs in total; nil when too few have arrived to know,
    /// negative when the frame announces a size no real block has.
    private func frameLength(for control: YAPPControlChar) -> Int? {
        switch control {
        case .soh:
            guard buffered.count >= 2 else { return nil }
            let second = Int(buffered[buffered.startIndex + 1])
            // A header carries at least "a\0" "0\0" "\0", five bytes, so a
            // length of 1 or 2 can only be send init or receive init.
            return (second == 0x01 || second == 0x02) ? 2 : 2 + second
        case .stx:
            guard buffered.count >= 3 else { return nil }
            let hi = Int(buffered[buffered.startIndex + 1])
            let lo = Int(buffered[buffered.startIndex + 2])
            let length = (hi << 8) | lo
            return length > Self.maxBlockBytes ? -1 : 3 + length + 1
        case .etx:
            return 2
        case .eot, .ack, .nak, .can:
            return 1
        }
    }
}
