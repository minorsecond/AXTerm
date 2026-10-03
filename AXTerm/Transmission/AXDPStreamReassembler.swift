//
//  AXDPStreamReassembler.swift
//  AXTerm
//
//  Cuts the byte stream from one peer into AXDP messages.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 6 (envelope)
//
//  Every message carries its own length (AXDP.headerLength), so where the
//  bytes were cut on the way does not matter: one frame per message, several
//  messages in a frame, or a node that re-cut the stream into frames of its
//  own all reassemble the same. Bytes before a magic are not AXDP and are
//  dropped here; the terminal sees them on its own path.
//

import Foundation

nonisolated struct AXDPStreamReassembler {

    /// Bytes held for a message whose end has not arrived yet, or the start
    /// of a magic split across deliveries. Never more than one message.
    private(set) var buffered = Data()

    /// Bytes thrown away because they were not part of a valid message.
    private(set) var discardedBytes = 0

    init(buffered: Data = Data()) {
        self.buffered = buffered
    }

    /// Whether a message has started and its end is still to come.
    var isMidMessage: Bool { AXDP.hasMagic(buffered) }

    /// Takes the next bytes of the stream and returns every message they
    /// complete, in order.
    mutating func append(_ data: Data) -> [AXDP.Message] {
        var buffer = AXDP.zeroBased(buffered + data)
        var messages: [AXDP.Message] = []

        while !buffer.isEmpty {
            guard let start = Self.magicOffset(in: buffer) else {
                // No message starts here. Keep a tail that could be the
                // first bytes of a magic finishing in the next delivery.
                let keep = Self.magicPrefixSuffixLength(of: buffer)
                discardedBytes += buffer.count - keep
                buffer = Data(buffer.suffix(keep))
                break
            }
            if start > 0 {
                discardedBytes += start
                buffer = Data(buffer.dropFirst(start))
            }
            switch AXDP.Message.frame(buffer) {
            case .message(let message, let consumed):
                messages.append(message)
                buffer = Data(buffer.dropFirst(consumed))
            case .needMore:
                buffered = buffer
                return messages
            case .invalid(let skip):
                discardedBytes += skip
                buffer = Data(buffer.dropFirst(skip))
            }
        }
        buffered = buffer
        return messages
    }

    /// Where the first magic starts, if anywhere.
    static func magicOffset(in data: Data) -> Int? {
        guard let range = data.range(of: AXDP.magic) else { return nil }
        return data.distance(from: data.startIndex, to: range.lowerBound)
    }

    /// The longest tail of `data` that is a proper prefix of the magic
    /// ("A", "AX" or "AXT"): a magic the next delivery may complete.
    static func magicPrefixSuffixLength(of data: Data) -> Int {
        for length in stride(from: min(AXDP.magic.count - 1, data.count), to: 0, by: -1)
        where data.suffix(length) == AXDP.magic.prefix(length) {
            return length
        }
        return 0
    }
}
