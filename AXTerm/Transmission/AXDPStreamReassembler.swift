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

    /// The message under way: how long it is, from its header, how much of
    /// it has arrived, and its type once the first TLV is in. Nil when no
    /// message has started or its header is still incomplete.
    var partial: AXDPPartialMessage? {
        let data = AXDP.zeroBased(buffered)
        guard AXDP.hasMagic(data), data.count >= AXDP.headerLength else { return nil }
        let total = Int(AXDP.decodeUInt16(data.subdata(in: AXDP.magic.count..<AXDP.headerLength)))
        guard total >= AXDP.minMessageLength else { return nil }
        // The encoder writes the type first: tag, a length of 1, the type.
        let tlv = AXDP.headerLength
        var type: AXDP.MessageType?
        if data.count >= tlv + 4, data[tlv] == AXDP.TLVType.messageType.rawValue,
           AXDP.decodeUInt16(data.subdata(in: (tlv + 1)..<(tlv + 3))) == 1 {
            type = AXDP.MessageType(rawValue: data[tlv + 3])
        }
        return AXDPPartialMessage(type: type, received: data.count, total: total)
    }

    /// Takes the next bytes of the stream and returns every message they
    /// complete, in order.
    mutating func append(_ data: Data) -> [AXDP.Message] {
        split(data).messages
    }

    /// Takes the next bytes of the stream and returns the messages they
    /// complete and the plain text around them, each in order.
    ///
    /// The text is every byte that is not part of a message: what came
    /// before a magic, and what follows a message's end. A tail that could be
    /// the start of a magic is held back, and given up as text at the next
    /// delivery if no magic follows. The terminal shows exactly this text, so
    /// a line that follows an AXDP message in the same delivery is not lost
    /// with it (home retest, 2026-10-10).
    mutating func split(_ data: Data) -> (messages: [AXDP.Message], text: Data) {
        var buffer = AXDP.zeroBased(buffered + data)
        var messages: [AXDP.Message] = []
        var text = Data()

        while !buffer.isEmpty {
            guard let start = Self.magicOffset(in: buffer) else {
                // No message starts here. Keep a tail that could be the
                // first bytes of a magic finishing in the next delivery.
                let keep = Self.magicPrefixSuffixLength(of: buffer)
                discardedBytes += buffer.count - keep
                text.append(buffer.prefix(buffer.count - keep))
                buffer = Data(buffer.suffix(keep))
                break
            }
            if start > 0 {
                discardedBytes += start
                text.append(buffer.prefix(start))
                buffer = Data(buffer.dropFirst(start))
            }
            switch AXDP.Message.frame(buffer) {
            case .message(let message, let consumed):
                messages.append(message)
                buffer = Data(buffer.dropFirst(consumed))
            case .needMore:
                buffered = buffer
                return (messages, text)
            case .invalid(let skip):
                discardedBytes += skip
                buffer = Data(buffer.dropFirst(skip))
            }
        }
        buffered = buffer
        return (messages, text)
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

/// An AXDP message partway in (`AXDPStreamReassembler.partial`).
nonisolated struct AXDPPartialMessage: Equatable {
    let type: AXDP.MessageType?
    let received: Int
    let total: Int

    /// "1.2 of 3.4 KB", or "300 of 900 bytes" for a short message.
    var amount: String {
        guard total >= 1000 else { return "\(received) of \(total) bytes" }
        return String(format: "%.1f of %.1f KB", Double(received) / 1000, Double(total) / 1000)
    }

    /// The line for a message the link cut off.
    func stoppedNotice(from peer: String) -> String {
        "The message from \(peer) stopped after \(amount), when the connection ended."
    }
}
