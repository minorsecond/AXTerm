import Foundation
import CryptoKit

/// A Winlink B2 message: the uncompressed unit that travels inside an
/// `FC EM` proposal (headers + body + attachments).
///
/// Wire layout (winlink.org/B2F):
///
///     Header lines, CRLF-terminated (Mid/Date/Type/From/To/Cc/Subject/Mbo/Body/File …)
///     CRLF (blank line)
///     Body bytes — exactly the count declared by `Body:`
///     CRLF
///     For each attachment, its bytes followed by CRLF
///
/// Headers and body are ISO-8859-1; attachments are arbitrary 8-bit data.
nonisolated struct WinlinkB2Message: Hashable, Sendable {

    enum MessageType: String, Sendable, CaseIterable {
        case privateMessage = "Private"
        case bulletin = "Bulletin"
        case service = "Service"
        case inquiry = "Inquiry"
        case positionReport = "Position Report"
        case positionRequest = "Position Request"
        case option = "Option"
        case system = "System"
    }

    struct Attachment: Hashable, Sendable {
        var name: String
        var data: Data
    }

    static let maxMIDLength = 12
    static let maxSubjectLength = 128

    var mid: String
    var date: Date
    var type: MessageType
    var from: String
    var to: [String]
    var cc: [String]
    var subject: String
    /// Message Box Operator: the station where the message entered the system.
    var mbo: String
    /// Body bytes, ISO-8859-1 with CRLF line endings.
    var body: Data
    var attachments: [Attachment]

    enum CodecError: Error, Equatable {
        case missingHeaderTerminator
        case missingRequiredHeader(String)
        case malformedHeader(String)
        case truncatedBody(expected: Int, available: Int)
        case truncatedAttachment(name: String, expected: Int, available: Int)
        case subjectTooLong
        case midTooLong
    }

    // MARK: - MID generation

    /// Generates a protocol-conformant unique message ID (≤12 chars,
    /// A–Z / 2–7 from the base32 alphabet, as the reference clients do).
    static func generateMID(callsign: String, date: Date = Date(), entropy: String = UUID().uuidString) -> String {
        let payload = "\(date.timeIntervalSince1970)-\(callsign)-\(entropy)"
        let sum = Array(Insecure.MD5.hash(data: Data(payload.utf8)))
        return String(base32Encode(sum).prefix(maxMIDLength))
    }

    private static func base32Encode(_ bytes: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 0x1f])
                bits -= 5
            }
        }
        if bits > 0 {
            out.append(alphabet[(buffer << (5 - bits)) & 0x1f])
        }
        return out
    }

    // MARK: - Encoding

    /// Serializes the message into its B2 wire form.
    func encode() throws -> Data {
        guard mid.count <= Self.maxMIDLength else { throw CodecError.midTooLong }
        guard subject.count <= Self.maxSubjectLength else { throw CodecError.subjectTooLong }

        var header = ""
        header += "Mid: \(mid)\r\n"
        header += "Date: \(Self.dateFormatter.string(from: date))\r\n"
        header += "Type: \(type.rawValue)\r\n"
        header += "From: \(from)\r\n"
        for address in to { header += "To: \(address)\r\n" }
        for address in cc { header += "Cc: \(address)\r\n" }
        header += "Subject: \(subject)\r\n"
        header += "Mbo: \(mbo)\r\n"
        header += "Body: \(body.count)\r\n"
        for attachment in attachments {
            header += "File: \(attachment.data.count) \(attachment.name)\r\n"
        }
        header += "\r\n"

        guard let headerData = header.data(using: .isoLatin1) else {
            throw CodecError.malformedHeader("header not representable in ISO-8859-1")
        }

        var out = headerData
        out.append(body)
        out.append(contentsOf: Self.crlf)
        for attachment in attachments {
            out.append(attachment.data)
            out.append(contentsOf: Self.crlf)
        }
        return out
    }

    // MARK: - Parsing

    /// Parses a B2 wire-form message. Unknown headers (e.g. `Content-Type`
    /// emitted by some gateways) are tolerated and ignored.
    static func parse(_ data: Data) throws -> WinlinkB2Message {
        let bytes = [UInt8](data)
        guard let headerEnd = findHeaderTerminator(bytes) else {
            throw CodecError.missingHeaderTerminator
        }

        guard let headerText = String(bytes: bytes[0..<headerEnd], encoding: .isoLatin1) else {
            throw CodecError.malformedHeader("undecodable header block")
        }

        var mid: String?
        var date: Date?
        var type: MessageType = .privateMessage
        var from: String?
        var to = [String]()
        var cc = [String]()
        var subject = ""
        var mbo = ""
        var bodyCount: Int?
        var files = [(size: Int, name: String)]()

        // Note: "\r\n" is a single grapheme cluster in Swift, so it must be
        // matched explicitly alongside the bare CR and LF characters.
        for rawLine in headerText.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\r\n" || $0 == "\r" || $0 == "\n" }) {
            let line = String(rawLine)
            guard let colon = line.firstIndex(of: ":") else {
                throw CodecError.malformedHeader(line)
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "mid": mid = value
            case "date": date = dateFormatter.date(from: value)
            case "type": type = MessageType(rawValue: value) ?? .privateMessage
            case "from": from = value
            case "to": to.append(value)
            case "cc": cc.append(value)
            case "subject": subject = value
            case "mbo": mbo = value
            case "body": bodyCount = Int(value)
            case "file":
                let parts = value.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let size = Int(parts[0]) else {
                    throw CodecError.malformedHeader(line)
                }
                files.append((size: size, name: String(parts[1])))
            default:
                break
            }
        }

        guard let mid else { throw CodecError.missingRequiredHeader("Mid") }
        guard let from else { throw CodecError.missingRequiredHeader("From") }
        let bodySize = bodyCount ?? 0

        var cursor = headerEnd + 4  // past CRLF CRLF
        guard cursor + bodySize <= bytes.count else {
            throw CodecError.truncatedBody(expected: bodySize, available: bytes.count - cursor)
        }
        let body = Data(bytes[cursor..<(cursor + bodySize)])
        cursor += bodySize
        cursor = skipCRLF(bytes, at: cursor)

        var attachments = [Attachment]()
        for file in files {
            guard cursor + file.size <= bytes.count else {
                throw CodecError.truncatedAttachment(
                    name: file.name, expected: file.size, available: bytes.count - cursor)
            }
            attachments.append(Attachment(name: file.name, data: Data(bytes[cursor..<(cursor + file.size)])))
            cursor += file.size
            cursor = skipCRLF(bytes, at: cursor)
        }

        return WinlinkB2Message(
            mid: mid,
            date: date ?? Date(timeIntervalSince1970: 0),
            type: type,
            from: from,
            to: to,
            cc: cc,
            subject: subject,
            mbo: mbo,
            body: body,
            attachments: attachments
        )
    }

    // MARK: - Helpers

    private static let crlf: [UInt8] = [0x0d, 0x0a]

    private static func findHeaderTerminator(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) {
            if bytes[i] == 0x0d, bytes[i + 1] == 0x0a, bytes[i + 2] == 0x0d, bytes[i + 3] == 0x0a {
                return i
            }
        }
        return nil
    }

    private static func skipCRLF(_ bytes: [UInt8], at index: Int) -> Int {
        var i = index
        if i < bytes.count, bytes[i] == 0x0d { i += 1 }
        if i < bytes.count, bytes[i] == 0x0a { i += 1 }
        return i
    }

    /// Protocol date format: `YYYY/MM/DD HH:MM` in UTC.
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
