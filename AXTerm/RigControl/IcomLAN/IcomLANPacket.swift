import Foundation

/// The Icom network protocol, as bytes: what RS-BA1, wfview and kappanhang
/// speak to an IC-705's WLAN. Three UDP streams — control, CI-V ("serial")
/// and audio — share one 16-byte header and one keepalive scheme; the
/// control stream adds login, a token and the connection request that
/// names the codec. Every layout here was worked out from the two open
/// implementations and is pinned in `IcomLANPacketTests`.
///
/// Header, little-endian except the two session IDs, which are opaque and
/// kept in the order the radio uses:
///
///     0  u32  length of the whole datagram
///     4  u16  type      (0 idle, 1 retransmit, 3 are-you-there, 4 I-am-here,
///                        5 disconnect, 6 ready, 7 ping)
///     6  u16  sequence  (tracked packets; the radio may ask for one again)
///     8  u32  sender's session ID
///    12  u32  receiver's session ID
nonisolated enum IcomLAN {
    static let controlPort: UInt16 = 50001
    static let serialPort: UInt16 = 50002
    static let audioPort: UInt16 = 50003

    enum PacketType: UInt16 {
        case idle = 0x00
        case retransmit = 0x01
        case areYouThere = 0x03
        case iAmHere = 0x04
        case disconnect = 0x05
        case ready = 0x06
        case ping = 0x07
    }

    struct Header: Equatable, Sendable {
        var length: UInt32
        var type: UInt16
        var sequence: UInt16
        var senderID: UInt32
        var receiverID: UInt32

        static let size = 16

        static func parse(_ d: Data) -> Header? {
            guard d.count >= size else { return nil }
            let b = [UInt8](d.prefix(size))
            return Header(length: le32(b, 0), type: le16(b, 4), sequence: le16(b, 6),
                          senderID: be32(b, 8), receiverID: be32(b, 12))
        }

        var bytes: [UInt8] {
            var out = [UInt8](repeating: 0, count: Header.size)
            putLE32(&out, 0, length); putLE16(&out, 4, type); putLE16(&out, 6, sequence)
            putBE32(&out, 8, senderID); putBE32(&out, 12, receiverID)
            return out
        }
    }

    // MARK: - Control packets (16 bytes)

    static func control(_ type: PacketType, sequence: UInt16 = 0, local: UInt32, remote: UInt32) -> Data {
        Data(Header(length: 16, type: type.rawValue, sequence: sequence, senderID: local, receiverID: remote).bytes)
    }

    /// Ask for one tracked packet again.
    static func retransmitRequest(sequence: UInt16, local: UInt32, remote: UInt32) -> Data {
        control(.retransmit, sequence: sequence, local: local, remote: remote)
    }

    /// Ask for ranges of tracked packets again: pairs of (first, last).
    static func retransmitRequest(ranges: [(UInt16, UInt16)], local: UInt32, remote: UInt32) -> Data {
        var out = Header(length: UInt32(16 + 4 * ranges.count), type: PacketType.retransmit.rawValue,
                         sequence: 0, senderID: local, receiverID: remote).bytes
        for (first, last) in ranges {
            out += [UInt8(first & 0xFF), UInt8(first >> 8), UInt8(last & 0xFF), UInt8(last >> 8)]
        }
        return Data(out)
    }

    // MARK: - Ping (21 bytes)

    /// Our own ping, or the answer to the radio's (same id, reply flag set).
    static func ping(sequence: UInt16, local: UInt32, remote: UInt32, reply: Bool, id: [UInt8]) -> Data {
        var out = Header(length: 21, type: PacketType.ping.rawValue, sequence: sequence,
                         senderID: local, receiverID: remote).bytes
        out.append(reply ? 0x01 : 0x00)
        out += Array(id.prefix(4)) + [UInt8](repeating: 0, count: max(0, 4 - id.count))
        return Data(out)
    }

    /// A ping has 21 bytes and type 7; the radio's copies sometimes carry a
    /// zero length byte, so only the type is trusted.
    static func isPing(_ d: Data) -> Bool {
        guard d.count == 21 else { return false }
        let b = [UInt8](d)
        return b[1] == 0 && b[2] == 0 && b[3] == 0 && b[4] == 0x07 && b[5] == 0
    }

    /// Whether a ping is the radio asking (false) or answering us (true).
    static func pingIsReply(_ d: Data) -> Bool { d.count == 21 && d[d.startIndex + 16] == 0x01 }
    static func pingID(_ d: Data) -> [UInt8] { [UInt8](d.dropFirst(17).prefix(4)) }

    static func isIdle(_ d: Data) -> Bool {
        d.count == 16 && d[d.startIndex + 4] == 0 && d[d.startIndex + 5] == 0
    }

    /// A retransmit request from the radio: the sequences it wants again.
    static func retransmitRequestedSequences(_ d: Data) -> [UInt16]? {
        guard let h = Header.parse(d), h.type == PacketType.retransmit.rawValue else { return nil }
        if d.count == 16 { return [h.sequence] }
        guard d.count >= 20 else { return nil }
        let b = [UInt8](d)
        var out: [UInt16] = []
        var i = 16
        while i + 3 < b.count {
            let first = le16(b, i), last = le16(b, i + 2)
            var s = first
            var guardCount = 0
            while guardCount < 64 {
                out.append(s)
                if s == last { break }
                s &+= 1
                guardCount += 1
            }
            i += 4
        }
        return out
    }

    // MARK: - Login (128 bytes)

    static func login(local: UInt32, remote: UInt32, innerSequence: UInt16, tokenRequest: (UInt8, UInt8),
                      username: String, password: String, program: String) -> Data {
        var out = [UInt8](repeating: 0, count: 128)
        out.replaceSubrange(0..<16, with: Header(length: 128, type: 0, sequence: 0, senderID: local, receiverID: remote).bytes)
        out[19] = 0x70             // payload size
        out[20] = 0x01             // request
        out[21] = 0x00             // login
        putLE16(&out, 23, innerSequence)
        out[26] = tokenRequest.0
        out[27] = tokenRequest.1
        out.replaceSubrange(64..<80, with: IcomPasscode.encode(username))
        out.replaceSubrange(80..<96, with: IcomPasscode.encode(password))
        out.replaceSubrange(96..<112, with: padded(program, 16))
        return Data(out)
    }

    struct LoginReply: Equatable, Sendable {
        let accepted: Bool
        let authID: [UInt8]
    }

    /// 96 bytes, first byte 0x60. `FF FF FF FE` at 48 means bad credentials.
    static func parseLoginReply(_ d: Data) -> LoginReply? {
        guard d.count == 96, d[d.startIndex] == 0x60 else { return nil }
        let b = [UInt8](d)
        let rejected = Array(b[48..<52]) == [0xFF, 0xFF, 0xFF, 0xFE]
        return LoginReply(accepted: !rejected, authID: Array(b[26..<32]))
    }

    // MARK: - Token (64 bytes)

    enum TokenAction: UInt8 {
        case release = 0x01
        case confirm = 0x02
        case renew = 0x05
    }

    static func token(_ action: TokenAction, local: UInt32, remote: UInt32, innerSequence: UInt16, authID: [UInt8]) -> Data {
        var out = [UInt8](repeating: 0, count: 64)
        out.replaceSubrange(0..<16, with: Header(length: 64, type: 0, sequence: 0, senderID: local, receiverID: remote).bytes)
        out[19] = 0x30
        out[20] = 0x01
        out[21] = action.rawValue
        putLE16(&out, 23, innerSequence)
        out.replaceSubrange(26..<32, with: Array(authID.prefix(6)) + [UInt8](repeating: 0, count: max(0, 6 - authID.count)))
        return Data(out)
    }

    /// 64 bytes, first byte 0x40: the action it answers is at 21.
    static func parseTokenReply(_ d: Data) -> TokenAction? {
        guard d.count == 64, d[d.startIndex] == 0x40 else { return nil }
        return TokenAction(rawValue: d[d.startIndex + 21])
    }

    // MARK: - Capabilities (168 bytes, from the radio)

    struct Capabilities: Equatable, Sendable {
        /// Sixteen bytes the connection request must echo.
        let replyID: [UInt8]
        let radioName: String
    }

    static func parseCapabilities(_ d: Data) -> Capabilities? {
        guard d.count == 168, d[d.startIndex] == 0xA8 else { return nil }
        let b = [UInt8](d)
        return Capabilities(replyID: Array(b[66..<82]), radioName: cString(b, from: 82, max: 16))
    }

    // MARK: - Status (80 bytes, from the radio)

    enum Status: Equatable, Sendable {
        case authFailed
        case radioDisconnected
        case other
    }

    static func parseStatus(_ d: Data) -> Status? {
        guard d.count == 80, d[d.startIndex] == 0x50 else { return nil }
        let b = [UInt8](d)
        if Array(b[48..<51]) == [0xFF, 0xFF, 0xFF] { return .authFailed }
        if Array(b[48..<51]) == [0, 0, 0], b[64] == 0x01 { return .radioDisconnected }
        return .other
    }

    // MARK: - Connection request (144 bytes)

    struct ConnectionRequest: Sendable {
        var radioName: String
        var username: String
        var sampleRate: UInt16 = 48_000
        /// 0x04: linear PCM, one channel, 16 bits. Never a lossy codec for packet.
        var codec: UInt8 = 0x04
        var serialPort: UInt16 = IcomLAN.serialPort
        var audioPort: UInt16 = IcomLAN.audioPort
        /// How much transmit audio the radio buffers before playing. Above
        /// about 500 ms the radio stops accepting TX audio.
        var txBufferMs: UInt16 = 300
    }

    static func connectionRequest(_ r: ConnectionRequest, local: UInt32, remote: UInt32, innerSequence: UInt16,
                                  authID: [UInt8], replyID: [UInt8]) -> Data {
        var out = [UInt8](repeating: 0, count: 144)
        out.replaceSubrange(0..<16, with: Header(length: 144, type: 0, sequence: 0, senderID: local, receiverID: remote).bytes)
        out[19] = 0x80
        out[20] = 0x01
        out[21] = 0x03
        putLE16(&out, 23, innerSequence)
        out.replaceSubrange(26..<32, with: Array(authID.prefix(6)) + [UInt8](repeating: 0, count: max(0, 6 - authID.count)))
        out.replaceSubrange(32..<48, with: Array(replyID.prefix(16)) + [UInt8](repeating: 0, count: max(0, 16 - replyID.count)))
        out.replaceSubrange(64..<96, with: padded(r.radioName, 32))
        out.replaceSubrange(96..<112, with: IcomPasscode.encode(r.username))
        out[112] = 0x01            // receive audio
        out[113] = 0x01            // transmit audio
        out[114] = r.codec
        out[115] = r.codec
        putBE16(&out, 118, r.sampleRate)
        putBE16(&out, 122, r.sampleRate)
        putBE16(&out, 126, r.serialPort)
        putBE16(&out, 130, r.audioPort)
        putBE16(&out, 134, r.txBufferMs)
        out[136] = 0x01
        return Data(out)
    }

    struct ConnectionReply: Equatable, Sendable {
        let accepted: Bool
        let deviceName: String
        let authID: [UInt8]
        let radioID: UInt32
        let ourID: UInt32
    }

    static func parseConnectionReply(_ d: Data) -> ConnectionReply? {
        guard d.count == 144, d[d.startIndex] == 0x90 else { return nil }
        let b = [UInt8](d)
        return ConnectionReply(accepted: b[96] == 0x01, deviceName: cString(b, from: 64, max: 32),
                               authID: Array(b[26..<32]), radioID: be32(b, 8), ourID: be32(b, 12))
    }

    // MARK: - CI-V stream

    /// Open (0x05) or close (0x00) the CI-V channel. 22 bytes.
    static func serialOpen(_ open: Bool, sendSequence: UInt16, local: UInt32, remote: UInt32) -> Data {
        var out = Header(length: 22, type: 0, sequence: 0, senderID: local, receiverID: remote).bytes
        out += [0xC0, 0x01, 0x00, UInt8(sendSequence >> 8), UInt8(sendSequence & 0xFF), open ? 0x05 : 0x00]
        return Data(out)
    }

    /// CI-V bytes, verbatim, after a 21-byte header.
    static func serialData(_ bytes: Data, sendSequence: UInt16, local: UInt32, remote: UInt32) -> Data {
        let n = UInt8(clamping: bytes.count)
        var out = Header(length: UInt32(21 + Int(n)), type: 0, sequence: 0, senderID: local, receiverID: remote).bytes
        out += [0xC1, n, 0x00, UInt8(sendSequence >> 8), UInt8(sendSequence & 0xFF)]
        out += [UInt8](bytes.prefix(Int(n)))
        return Data(out)
    }

    /// The CI-V bytes inside a serial data packet, or nil for anything else.
    static func serialPayload(_ d: Data) -> Data? {
        guard d.count >= 22, let h = Header.parse(d), h.length == UInt32(d.count) else { return nil }
        let b = [UInt8](d)
        guard b[16] == 0xC1, Int(b[17]) == d.count - 21 else { return nil }
        return Data(b[21...])
    }

    // MARK: - Audio stream

    /// Linear PCM after a 24-byte header. The radio takes 20 ms of 48 kHz
    /// mono per pair of packets, 1364 + 556 bytes, and that is what we send.
    static func audioData(_ pcm: Data, sendSequence: UInt16, local: UInt32, remote: UInt32) -> Data {
        var out = Header(length: UInt32(24 + pcm.count), type: 0, sequence: 0, senderID: local, receiverID: remote).bytes
        out += [0x80, 0x00, UInt8(sendSequence >> 8), UInt8(sendSequence & 0xFF), 0x00, 0x00,
                UInt8(pcm.count >> 8), UInt8(pcm.count & 0xFF)]
        out += [UInt8](pcm)
        return Data(out)
    }

    static let audioChunkSizes = [1364, 556]

    /// PCM after the 24-byte header. The radio's audio packets do not all
    /// carry the 0x80 marker the transmit ones do, so any length-matching
    /// packet larger than the header on the audio stream is treated as
    /// audio; control, ping and retransmit packets are filtered before this.
    static func audioPayload(_ d: Data) -> Data? {
        guard d.count > 24, let h = Header.parse(d), h.length == UInt32(d.count) else { return nil }
        return Data(d[(d.startIndex + 24)...])
    }

    // MARK: - Byte helpers

    static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    static func putLE16(_ b: inout [UInt8], _ i: Int, _ v: UInt16) { b[i] = UInt8(v & 0xFF); b[i + 1] = UInt8(v >> 8) }
    static func putBE16(_ b: inout [UInt8], _ i: Int, _ v: UInt16) { b[i] = UInt8(v >> 8); b[i + 1] = UInt8(v & 0xFF) }
    static func putLE32(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
        b[i] = UInt8(v & 0xFF); b[i + 1] = UInt8((v >> 8) & 0xFF); b[i + 2] = UInt8((v >> 16) & 0xFF); b[i + 3] = UInt8(v >> 24)
    }
    static func putBE32(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
        b[i] = UInt8(v >> 24); b[i + 1] = UInt8((v >> 16) & 0xFF); b[i + 2] = UInt8((v >> 8) & 0xFF); b[i + 3] = UInt8(v & 0xFF)
    }

    static func padded(_ s: String, _ n: Int) -> [UInt8] {
        var out = [UInt8](s.utf8.prefix(n - 1))
        out += [UInt8](repeating: 0, count: n - out.count)
        return out
    }

    static func cString(_ b: [UInt8], from: Int, max: Int) -> String {
        guard from < b.count else { return "" }
        let slice = b[from..<min(b.count, from + max)]
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(decoding: slice[slice.startIndex..<end], as: UTF8.self)
    }
}

/// Icom's credential obfuscation: each character, offset by its position,
/// looked up in a fixed table. It is not encryption and it protects nothing;
/// it is simply what the radio expects.
nonisolated enum IcomPasscode {
    private static let table: [UInt8] = [
        0x47, 0x5d, 0x4c, 0x42, 0x66, 0x20, 0x23, 0x46, 0x4e, 0x57, 0x45, 0x3d, 0x67, 0x76, 0x60, 0x41,
        0x62, 0x39, 0x59, 0x2d, 0x68, 0x7e, 0x7c, 0x65, 0x7d, 0x49, 0x29, 0x72, 0x73, 0x78, 0x21, 0x6e,
        0x5a, 0x5e, 0x4a, 0x3e, 0x71, 0x2c, 0x2a, 0x54, 0x3c, 0x3a, 0x63, 0x4f, 0x43, 0x75, 0x27, 0x79,
        0x5b, 0x35, 0x70, 0x48, 0x6b, 0x56, 0x6f, 0x34, 0x32, 0x6c, 0x30, 0x61, 0x6d, 0x7b, 0x2f, 0x4b,
        0x64, 0x38, 0x2b, 0x2e, 0x50, 0x40, 0x3f, 0x55, 0x33, 0x37, 0x25, 0x77, 0x24, 0x26, 0x74, 0x6a,
        0x28, 0x53, 0x4d, 0x69, 0x22, 0x5c, 0x44, 0x31, 0x36, 0x58, 0x3b, 0x7a, 0x51, 0x5f, 0x52,
    ]

    /// Sixteen bytes; longer strings are cut, shorter ones zero-padded.
    static func encode(_ s: String) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for (i, c) in s.utf8.prefix(16).enumerated() {
            var p = Int(c) + i
            if p > 126 { p = 32 + p % 127 }
            let index = p - 32
            out[i] = (0..<table.count).contains(index) ? table[index] : 0
        }
        return out
    }
}
