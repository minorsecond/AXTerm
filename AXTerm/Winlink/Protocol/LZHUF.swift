import Foundation

/// LZHUF compression as used by the binary FBB protocols (B, B1, B2) for
/// Winlink mail transfer.
///
/// This is a faithful port of the reference implementation in
/// la5nta/wl2k-go (`lzhuf` package, MIT), itself derived from Haruyasu
/// Yoshizaki's original LZHUF.C. The B2F framing prepends a CRC16 of the
/// compressed stream (Xmodem CRC-CCITT variant) and a little-endian
/// 32-bit uncompressed length:
///
///     [crc16 LE (2)] [uncompressed length LE (4)] [lzhuf bit stream]
///
/// Interop is guarded by byte-exact fixtures in LZHUFTests — do not
/// "clean up" the algorithm; wire compatibility depends on every table
/// and traversal order below.
nonisolated enum LZHUF {

    enum DecodeError: Error, Equatable {
        case truncated
        /// The CRC16 over the compressed body did not match its header.
        /// The bytes are wrong: a bad resume stitch, or corruption on the
        /// way in.
        case checksumMismatch
        /// The CRC16 *passed* — so the compressed bytes are provably
        /// correct — but decompressing them produced the wrong number of
        /// bytes. That is a decoder fault, not a link fault, and the two
        /// must never share an error case: they send an investigation in
        /// opposite directions.
        case decodedSizeMismatch(expected: Int, actual: Int)
        case invalidHeader
    }

    /// Bytes in the B2F wire header: CRC16 (2) + uncompressed length (4).
    /// On a resumed transfer the sender re-sends exactly these bytes ahead
    /// of the continuation (field capture 2026-08-24, W0ARP-10).
    static let wireHeaderSize = 6

    /// Compresses `data` into the B2F wire format (CRC16 + length + stream).
    static func encodeB2F(_ data: Data) -> Data {
        let encoder = Encoder()
        encoder.write(data)
        let stream = encoder.finish()

        let size = Int32(truncatingIfNeeded: data.count)
        let sizeBytes: [UInt8] = [
            UInt8(truncatingIfNeeded: size),
            UInt8(truncatingIfNeeded: size >> 8),
            UInt8(truncatingIfNeeded: size >> 16),
            UInt8(truncatingIfNeeded: size >> 24),
        ]

        let crc = FBBCRC16.checksum(sizeBytes + stream)
        var out = Data(capacity: stream.count + 6)
        out.append(UInt8(truncatingIfNeeded: crc))
        out.append(UInt8(truncatingIfNeeded: crc >> 8))
        out.append(contentsOf: sizeBytes)
        out.append(contentsOf: stream)
        return out
    }

    /// Decompresses a B2F wire-format payload, verifying the CRC16 and the
    /// declared uncompressed length.
    static func decodeB2F(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else { throw DecodeError.truncated }

        let storedCRC = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard FBBCRC16.checksum(bytes[2...]) == storedCRC else {
            throw DecodeError.checksumMismatch
        }

        let size = Int(UInt32(bytes[2]) | (UInt32(bytes[3]) << 8) | (UInt32(bytes[4]) << 16) | (UInt32(bytes[5]) << 24))
        // Winlink caps messages far below this; anything larger is a corrupt header.
        guard size <= 32 * 1024 * 1024 else { throw DecodeError.invalidHeader }

        let decoder = Decoder(input: Array(bytes[6...]))
        let out = try decoder.decodeAll(expectedSize: size)
        return Data(out)
    }

    // MARK: - Algorithm constants

    fileprivate static let bufferSize = 2048              // _N: ring buffer size
    fileprivate static let lookahead = 60                 // _F: lookahead buffer size
    fileprivate static let nilNode = bufferSize           // _NIL: tree leaf marker
    fileprivate static let threshold = 2                  // _Threshold
    fileprivate static let numChar = 256 - threshold + lookahead  // _NumChar = 314
    fileprivate static let tableSize = numChar * 2 - 1    // _T = 627
    fileprivate static let rootPos = tableSize - 1        // _R = 626
    fileprivate static let maxFreq = 0x8000               // _MaxFreq

    // MARK: - Position-code tables (upper 6 bits of match position)

    fileprivate static let pCode: [UInt8] = [
        0x00, 0x20, 0x30, 0x40, 0x50, 0x58, 0x60, 0x68,
        0x70, 0x78, 0x80, 0x88, 0x90, 0x94, 0x98, 0x9C,
        0xA0, 0xA4, 0xA8, 0xAC, 0xB0, 0xB4, 0xB8, 0xBC,
        0xC0, 0xC2, 0xC4, 0xC6, 0xC8, 0xCA, 0xCC, 0xCE,
        0xD0, 0xD2, 0xD4, 0xD6, 0xD8, 0xDA, 0xDC, 0xDE,
        0xE0, 0xE2, 0xE4, 0xE6, 0xE8, 0xEA, 0xEC, 0xEE,
        0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7,
        0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF,
    ]

    fileprivate static let pLen: [UInt8] = [
        0x03, 0x04, 0x04, 0x04, 0x05, 0x05, 0x05, 0x05,
        0x05, 0x05, 0x05, 0x05, 0x06, 0x06, 0x06, 0x06,
        0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
        0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
        0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
    ]

    fileprivate static let dCode: [UInt8] = {
        var t = [UInt8]()
        t.reserveCapacity(256)
        // Runs of identical values: (value count) pairs mirror the reference table.
        let runs: [(UInt8, Int)] = [
            (0x00, 32), (0x01, 16), (0x02, 16), (0x03, 16),
            (0x04, 8), (0x05, 8), (0x06, 8), (0x07, 8),
            (0x08, 8), (0x09, 8), (0x0A, 8), (0x0B, 8),
            (0x0C, 4), (0x0D, 4), (0x0E, 4), (0x0F, 4),
            (0x10, 4), (0x11, 4), (0x12, 4), (0x13, 4),
            (0x14, 4), (0x15, 4), (0x16, 4), (0x17, 4),
            (0x18, 2), (0x19, 2), (0x1A, 2), (0x1B, 2),
            (0x1C, 2), (0x1D, 2), (0x1E, 2), (0x1F, 2),
            (0x20, 2), (0x21, 2), (0x22, 2), (0x23, 2),
            (0x24, 2), (0x25, 2), (0x26, 2), (0x27, 2),
            (0x28, 2), (0x29, 2), (0x2A, 2), (0x2B, 2),
            (0x2C, 2), (0x2D, 2), (0x2E, 2), (0x2F, 2),
        ]
        for (value, count) in runs { t.append(contentsOf: repeatElement(value, count: count)) }
        for value in UInt8(0x30)...UInt8(0x3F) { t.append(value) }
        precondition(t.count == 256)
        return t
    }()

    fileprivate static let dLen: [UInt8] = {
        var t = [UInt8]()
        t.reserveCapacity(256)
        // Each position code of length L covers 2^(8-L) byte prefixes,
        // matching the pLen distribution: 1×3-bit, 3×4, 8×5, 12×6, 24×7, 16×8.
        t.append(contentsOf: repeatElement(0x03, count: 32))
        t.append(contentsOf: repeatElement(0x04, count: 48))
        t.append(contentsOf: repeatElement(0x05, count: 64))
        t.append(contentsOf: repeatElement(0x06, count: 48))
        t.append(contentsOf: repeatElement(0x07, count: 48))
        t.append(contentsOf: repeatElement(0x08, count: 16))
        precondition(t.count == 256)
        return t
    }()
}

// MARK: - Adaptive Huffman tree + LZSS ring buffer

private nonisolated final class LZHUFState {
    typealias C = LZHUF

    var freq = [Int](repeating: 0, count: C.tableSize + 1)
    var prnt = [Int](repeating: 0, count: C.tableSize + C.numChar)
    var son = [Int](repeating: 0, count: C.tableSize)

    var dad = [Int](repeating: 0, count: C.bufferSize + 1)
    var lson = [Int](repeating: 0, count: C.bufferSize + 1)
    var rson = [Int](repeating: 0, count: C.bufferSize + 257)

    var textBuf = [UInt8](repeating: 0, count: C.bufferSize + C.lookahead - 1)
    var matchLength = 0
    var matchPosition = 0

    init() {
        for i in 0..<C.numChar {
            freq[i] = 1
            son[i] = i + C.tableSize
            prnt[i + C.tableSize] = i
        }
        var i = 0
        var j = C.numChar
        while j <= C.rootPos {
            freq[j] = freq[i] + freq[i + 1]
            son[j] = i
            prnt[i] = j
            prnt[i + 1] = j
            i += 2
            j += 1
        }
        freq[C.tableSize] = 0xffff
        prnt[C.rootPos] = 0
    }

    func initTree() {
        for i in (C.bufferSize + 1)...(C.bufferSize + 256) { rson[i] = C.nilNode }
        for i in 0..<C.bufferSize { dad[i] = C.nilNode }
    }

    func deleteNode(_ p: Int) {
        if dad[p] == C.nilNode { return }

        var q: Int
        if rson[p] == C.nilNode {
            q = lson[p]
        } else if lson[p] == C.nilNode {
            q = rson[p]
        } else {
            q = lson[p]
            if rson[q] != C.nilNode {
                while rson[q] != C.nilNode { q = rson[q] }
                rson[dad[q]] = lson[q]
                dad[lson[q]] = dad[q]
                lson[q] = lson[p]
                dad[lson[p]] = q
            }
            rson[q] = rson[p]
            dad[rson[p]] = q
        }

        dad[q] = dad[p]
        if rson[dad[p]] == p {
            rson[dad[p]] = q
        } else {
            lson[dad[p]] = q
        }

        dad[p] = C.nilNode
    }

    func insertNode(_ r: Int) {
        var cmp = 1
        var p = C.bufferSize + 1 + Int(textBuf[r])
        rson[r] = C.nilNode
        lson[r] = C.nilNode
        matchLength = 0

        while true {
            if cmp >= 0 {
                if rson[p] != C.nilNode {
                    p = rson[p]
                } else {
                    rson[p] = r
                    dad[r] = p
                    return
                }
            } else {
                if lson[p] != C.nilNode {
                    p = lson[p]
                } else {
                    lson[p] = r
                    dad[r] = p
                    return
                }
            }

            var i = 1
            while i < C.lookahead {
                cmp = Int(textBuf[r + i]) - Int(textBuf[p + i])
                if cmp != 0 { break }
                i += 1
            }
            if i > C.threshold {
                if i > matchLength {
                    matchPosition = ((r - p) & (C.bufferSize - 1)) - 1
                    matchLength = i
                    if matchLength >= C.lookahead { break }
                }
                if i == matchLength {
                    let c = ((r - p) & (C.bufferSize - 1)) - 1
                    if c < matchPosition { matchPosition = c }
                }
            }
        }

        dad[r] = dad[p]
        lson[r] = lson[p]
        rson[r] = rson[p]
        dad[lson[p]] = r
        dad[rson[p]] = r
        if rson[dad[p]] == p {
            rson[dad[p]] = r
        } else {
            lson[dad[p]] = r
        }
        dad[p] = C.nilNode
    }

    private func reconst() {
        // Collect leaf nodes in the first half of the table,
        // replacing each freq by (freq + 1) / 2.
        var j = 0
        for i in 0..<C.tableSize where son[i] >= C.tableSize {
            freq[j] = (freq[i] + 1) / 2
            son[j] = son[i]
            j += 1
        }

        // Reconnect children, keeping the table freq-sorted.
        var i = 0
        j = C.numChar
        while j < C.tableSize {
            let k0 = i + 1
            freq[j] = freq[i] + freq[k0]

            let first = freq[j]
            var k = j
            while first < freq[k - 1] { k -= 1 }

            let last = j - k
            var m = k + last
            while m > k {
                freq[m] = freq[m - 1]
                son[m] = son[m - 1]
                m -= 1
            }
            freq[k] = first
            son[k] = i

            i += 2
            j += 1
        }

        // Reconnect parents.
        for i in 0..<C.tableSize {
            let k = son[i]
            if k >= C.tableSize {
                prnt[k] = i
            } else {
                prnt[k + 1] = i
                prnt[k] = i
            }
        }
    }

    func update(_ char: Int) {
        if freq[C.rootPos] == C.maxFreq { reconst() }

        var c = prnt[char + C.tableSize]
        while true {
            freq[c] += 1

            if freq[c] <= freq[c + 1] || c + 2 >= freq.count {
                c = prnt[c]
                if c == 0 { break }
                continue
            }

            // Swap nodes to restore frequency ordering.
            var l = c + 1
            let k = freq[c]
            while k > freq[l + 1] { l += 1 }

            freq[c] = freq[l]
            freq[l] = k

            let i = son[c]
            prnt[i] = l
            if i < C.tableSize { prnt[i + 1] = l }

            let j = son[l]
            son[l] = i

            prnt[j] = c
            if j < C.tableSize { prnt[j + 1] = c }
            son[c] = j

            c = prnt[l]
            if c == 0 { break }
        }
    }
}

// MARK: - Encoder

private nonisolated final class Encoder {
    typealias C = LZHUF

    private let z = LZHUFState()
    private var out = [UInt8]()

    private var putbuf: UInt64 = 0
    private var putlen = 0

    private var len = 0
    private var r = C.bufferSize - C.lookahead
    private var s = 0
    private var lastMatchLength = 0
    private var preFilled = false

    init() {
        z.initTree()
        for i in 0..<r { z.textBuf[i] = 0x20 }
    }

    func write(_ p: Data) {
        var index = p.startIndex
        while !preFilled && index < p.endIndex {
            z.textBuf[r + len] = p[index]
            index = p.index(after: index)
            len += 1
            z.insertNode(r - len)
            lastMatchLength = 1
            preFilled = len == C.lookahead
        }

        while index < p.endIndex {
            advance(p[index])
            index = p.index(after: index)
        }
    }

    func finish() -> [UInt8] {
        while len > 0 { advance(nil) }
        encode()
        if putlen > 0 { out.append(UInt8(truncatingIfNeeded: putbuf >> 8)) }
        return out
    }

    private func advance(_ c: UInt8?) {
        if let c {
            z.textBuf[s] = c
            if s < C.lookahead - 1 { z.textBuf[s + C.bufferSize] = c }
            len += 1
        }

        z.insertNode(r)
        lastMatchLength -= 1
        if lastMatchLength == 0 { encode() }
        z.deleteNode(s)
        s = (s + 1) & (C.bufferSize - 1)
        r = (r + 1) & (C.bufferSize - 1)
        len -= 1
    }

    private func encode() {
        if len == 0 { return }

        if z.matchLength > len { z.matchLength = len }
        if z.matchLength <= C.threshold {
            z.matchLength = 1
            encodeChar(Int(z.textBuf[r]))
        } else {
            encodeChar(255 - C.threshold + z.matchLength)
            encodePosition(UInt64(z.matchPosition))
        }

        lastMatchLength = z.matchLength
    }

    private func encodeChar(_ c: Int) {
        // Travel from leaf to root, accumulating the code MSB-first.
        var i: UInt64 = 0
        var j = 0
        var k = z.prnt[c + C.tableSize]
        repeat {
            i >>= 1
            j += 1
            // If the node address is odd-numbered, choose the bigger brother node.
            if k & 1 != 0 { i += 0x8000 }
            k = z.prnt[k]
        } while k != C.rootPos

        putCode(j, i)
        z.update(c)
    }

    private func encodePosition(_ c: UInt64) {
        // Upper 6 bits by table lookup, lower 6 bits verbatim.
        let i = Int(c >> 6)
        putCode(Int(C.pLen[i]), UInt64(C.pCode[i]) << 8)
        putCode(6, (c & 0x3f) << 10)
    }

    private func putCode(_ l: Int, _ c: UInt64) {
        putbuf |= c >> UInt64(putlen)
        putlen += l
        if putlen < 8 { return }

        out.append(UInt8(truncatingIfNeeded: putbuf >> 8))
        putlen -= 8

        if putlen >= 8 {
            out.append(UInt8(truncatingIfNeeded: putbuf))
            putlen -= 8
            putbuf = c << UInt64(l - putlen)
        } else {
            putbuf <<= 8
        }
    }
}

// MARK: - Decoder

private nonisolated final class Decoder {
    typealias C = LZHUF

    private let z = LZHUFState()
    /// Ring-buffer write position. LZHUF.C starts this at N − F, which is
    /// also where the space pre-fill in `init` ends and what the encoder
    /// uses.
    ///
    /// This previously read `bufferSize - rootPos`, mixing in a Huffman
    /// *tree* index (626) that has nothing to do with the ring buffer,
    /// giving 1422 instead of 1988 — disagreeing with both the encoder and
    /// this decoder's own pre-fill loop.
    ///
    /// Corrected for consistency, not for observable behaviour: a
    /// differential run over 4000 space-heavy bodies found zero outputs
    /// where the two values disagree. All reads are relative to `r`, so a
    /// different starting offset shifts writes and reads together, and the
    /// pre-fill is uniform across the region either value can reach. Do
    /// not cite this as a fix for a decode failure.
    private var r = C.bufferSize - C.lookahead

    private let input: [UInt8]
    private var inPos = 0
    private var bitBuf: UInt64 = 0
    private var bitCount = 0
    private var truncated = false

    init(input: [UInt8]) {
        for i in 0..<(C.bufferSize - C.lookahead) { z.textBuf[i] = 0x20 }
        self.input = input
    }

    func decodeAll(expectedSize: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(expectedSize)

        while out.count < expectedSize {
            let c = decodeChar()
            if truncated { throw LZHUF.DecodeError.truncated }

            if c < 256 {
                emit(UInt8(truncatingIfNeeded: c), into: &out)
                continue
            }

            let position = decodePosition()
            if truncated { throw LZHUF.DecodeError.truncated }

            let start = (r - position - 1) & (C.bufferSize - 1)
            let matchLen = c - 255 + C.threshold
            for k in 0..<matchLen {
                emit(z.textBuf[(start + k) & (C.bufferSize - 1)], into: &out)
            }
        }

        // A final match run may not overshoot the declared size in a valid
        // stream. Reaching here means the CRC16 already passed, so the
        // compressed bytes are sound and the fault is ours.
        guard out.count == expectedSize else {
            throw LZHUF.DecodeError.decodedSizeMismatch(
                expected: expectedSize, actual: out.count)
        }
        return out
    }

    private func emit(_ byte: UInt8, into out: inout [UInt8]) {
        out.append(byte)
        z.textBuf[r] = byte
        r = (r + 1) & (C.bufferSize - 1)
    }

    private func decodeChar() -> Int {
        var c = z.son[C.rootPos]

        // Travel from root to leaf: smaller child if the bit is 0, bigger if 1.
        while c < C.tableSize {
            c += getBits(1)
            c = z.son[c]
        }
        c -= C.tableSize
        z.update(c)
        return c
    }

    private func decodePosition() -> Int {
        // Recover upper 6 bits from the table, then read the low bits verbatim.
        var i = getBits(8)
        let c = Int(C.dCode[i]) << 6
        var j = Int(C.dLen[i]) - 2
        while j > 0 {
            i = (i << 1) + getBits(1)
            j -= 1
        }
        return c | (i & 0x3f)
    }

    private func getBits(_ count: Int) -> Int {
        while bitCount < count {
            guard inPos < input.count else {
                truncated = true
                return 0
            }
            bitBuf = (bitBuf << 8) | UInt64(input[inPos])
            inPos += 1
            bitCount += 8
        }
        let value = Int((bitBuf >> UInt64(bitCount - count)) & ((1 << UInt64(count)) - 1))
        bitCount -= count
        return value
    }
}
