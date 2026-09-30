//
//  YAPPFrameAssembler.swift
//  AXTerm
//
//  Separates a caller's YAPP replies from what they type, during a download.
//

import Foundation

/// Cuts the caller's side of a mailbox download into YAPP replies and text.
///
/// While the mailbox sends a file, all that should come back is the
/// receiver's replies: RR, RF or RT, AF, AT, a NAK, a CAN. A caller whose
/// software does not speak YAPP sees the protocol bytes as noise and types
/// `A` to stop, and that has to be heard. `YAPPProtocol` parses its own
/// stream, so the replies are passed to it whole; this only decides which
/// bytes are replies.
///
/// Frame lengths are YAPP's own (the WA7MBL table, as `YAPPFrameParser`
/// reads it):
///
/// | Lead byte | Frame | Length |
/// |---|---|---|
/// | ENQ, ACK, ETX, EOT | two-byte frames | 2 |
/// | SOH, NAK, CAN, DLE | counted frames | 2 + n |
/// | STX | data block | 2 + n (0 means 256) |
///
/// A data block's checksum byte depends on what the transfer negotiated,
/// which only the protocol knows, so uploads (the only direction a caller
/// sends blocks in) go to the protocol raw and never through here.
nonisolated struct YAPPFrameAssembler: Equatable, Sendable {

    enum Piece: Equatable, Sendable {
        case frame(Data)
        case text(Data)
    }

    private(set) var buffered = Data()

    var isEmpty: Bool { buffered.isEmpty }

    mutating func push(_ data: Data) -> [Piece] {
        buffered.append(data)
        var pieces: [Piece] = []

        while let lead = buffered.first {
            if Self.opensFrame(lead) {
                guard let length = frameLength() else { break }
                guard buffered.count >= length else { break }
                pieces.append(.frame(Data(buffered.prefix(length))))
                buffered = Data(buffered.dropFirst(length))
            } else {
                // A run of text, up to the next byte that could open a frame.
                let end = buffered.firstIndex(where: Self.opensFrame) ?? buffered.endIndex
                pieces.append(.text(Data(buffered[buffered.startIndex..<end])))
                buffered = Data(buffered[end...])
            }
        }
        return pieces
    }

    mutating func reset() { buffered.removeAll() }

    static func opensFrame(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x10, 0x15, 0x18: return true
        default: return false
        }
    }

    /// Bytes this frame needs in total; nil when too few have arrived to know.
    private func frameLength() -> Int? {
        guard buffered.count >= 2 else { return nil }
        let lead = buffered[buffered.startIndex]
        let second = Int(buffered[buffered.startIndex + 1])
        switch lead {
        case 0x05, 0x06, 0x03, 0x04: return 2
        case 0x02: return 2 + (second == 0 ? 256 : second)
        default: return 2 + second
        }
    }
}
