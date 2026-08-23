import Foundation

/// FBB binary block framing for compressed message bodies.
///
/// After a proposal is accepted, its compressed payload travels as:
///
///     SOH (0x01)  len  title  NUL  offset-string  NUL
///     STX (0x02)  len  <len data bytes>      (len 0 means 256; repeated)
///     EOT (0x04)  checksum                   ((sum(data)+checksum)%256==0)
///
/// The checksum covers the STX payload bytes only. Senders keep blocks at
/// 125 bytes or fewer to stay friendly with small paclens; receivers must
/// accept any block size including the 256-byte `len == 0` encoding.
nonisolated enum FBBBlockCodec {

    static let soh: UInt8 = 0x01
    static let stx: UInt8 = 0x02
    static let eot: UInt8 = 0x04
    static let maxSendBlockSize = 125

    // MARK: - Encoding

    /// Frames a compressed payload for transmission, starting at `offset`
    /// (non-zero when the receiver requested a partial resume).
    static func encode(title: String, offset: Int, payload: Data) -> Data {
        var out = Data()

        let titleBytes = Array(title.utf8)
        let offsetBytes = Array(String(offset).utf8)
        out.append(soh)
        out.append(UInt8(titleBytes.count + offsetBytes.count + 2))
        out.append(contentsOf: titleBytes)
        out.append(0x00)
        out.append(contentsOf: offsetBytes)
        out.append(0x00)

        let body = payload.dropFirst(offset)
        var checksum: UInt8 = 0
        var index = body.startIndex
        while index < body.endIndex {
            let end = body.index(index, offsetBy: maxSendBlockSize, limitedBy: body.endIndex) ?? body.endIndex
            let chunk = body[index..<end]
            out.append(stx)
            out.append(UInt8(chunk.count))
            out.append(contentsOf: chunk)
            for byte in chunk { checksum = checksum &+ byte }
            index = end
        }

        out.append(eot)
        out.append(UInt8(truncatingIfNeeded: 0 &- Int(checksum)))
        return out
    }

    // MARK: - Incremental decoding

    enum Event: Equatable, Sendable {
        case header(title: String, offset: Int)
        case progress(bytesReceived: Int)
        case completed(payload: Data)
        case checksumFailure
        case protocolError(String)
    }

    /// Incremental parser: feed it raw session bytes, collect events.
    /// Safe against arbitrary chunk boundaries — state is kept between
    /// `feed` calls.
    final class Parser {
        private enum State {
            case expectSOH
            case headerLength
            case headerBody(remaining: Int, collected: [UInt8])
            case blockMarker
            case blockLength
            case blockBody(remaining: Int)
            case checksum
            case done
        }

        private var state: State = .expectSOH
        private var payload = Data()
        private var runningSum: UInt8 = 0

        var isComplete: Bool {
            if case .done = state { return true }
            return false
        }

        func feed(_ data: Data) -> [Event] {
            var events = [Event]()
            for byte in data {
                if let event = consume(byte) {
                    events.append(event)
                    if case .protocolError = event { break }
                    if case .checksumFailure = event { break }
                }
            }
            return events
        }

        private func consume(_ byte: UInt8) -> Event? {
            switch state {
            case .expectSOH:
                guard byte == FBBBlockCodec.soh else {
                    state = .done
                    return .protocolError(String(format: "expected SOH, got 0x%02X", byte))
                }
                state = .headerLength
                return nil

            case .headerLength:
                state = .headerBody(remaining: Int(byte), collected: [])
                return nil

            case .headerBody(let remaining, var collected):
                collected.append(byte)
                if remaining > 1 {
                    state = .headerBody(remaining: remaining - 1, collected: collected)
                    return nil
                }
                state = .blockMarker
                let fields = collected.split(separator: 0x00, omittingEmptySubsequences: false)
                let title = fields.count > 0 ? String(bytes: fields[0], encoding: .isoLatin1) ?? "" : ""
                let offset = fields.count > 1 ? Int(String(bytes: fields[1], encoding: .isoLatin1) ?? "0") ?? 0 : 0
                return .header(title: title, offset: offset)

            case .blockMarker:
                switch byte {
                case FBBBlockCodec.stx:
                    state = .blockLength
                    return nil
                case FBBBlockCodec.eot:
                    state = .checksum
                    return nil
                default:
                    state = .done
                    return .protocolError(String(format: "expected STX or EOT, got 0x%02X", byte))
                }

            case .blockLength:
                state = .blockBody(remaining: byte == 0 ? 256 : Int(byte))
                return nil

            case .blockBody(let remaining):
                payload.append(byte)
                runningSum = runningSum &+ byte
                if remaining > 1 {
                    state = .blockBody(remaining: remaining - 1)
                    return nil
                }
                state = .blockMarker
                return .progress(bytesReceived: payload.count)

            case .checksum:
                state = .done
                if runningSum &+ byte == 0 {
                    return .completed(payload: payload)
                }
                return .checksumFailure

            case .done:
                return .protocolError("bytes after EOT")
            }
        }
    }
}
