import Foundation

/// The AX.25 frame check sequence: CRC-16/X-25.
///
/// Reflected polynomial 0x1021 (table constant 0x8408), initial register
/// 0xFFFF, final complement. The transmitter appends `~crc` least
/// significant byte first; a receiver that keeps running the register over
/// the payload *and* those two bytes, without the final complement, lands
/// on the constant 0xF0B8 for every good frame — which is how the decoder
/// checks without knowing where the payload ends.
///
/// Published check value: `compute("123456789") == 0x906E`.
nonisolated enum CRC16X25 {

    /// The register value a good frame (payload + FCS) always leaves behind.
    static let goodResidue: UInt16 = 0xF0B8

    private static let table: [UInt16] = (0..<256).map { index -> UInt16 in
        var crc = UInt16(index)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1
        }
        return crc
    }

    @inline(__always)
    static func update(_ crc: UInt16, with byte: UInt8) -> UInt16 {
        (crc >> 8) ^ table[Int((crc ^ UInt16(byte)) & 0xFF)]
    }

    /// The FCS of a payload, as a number (complemented, ready to send LSB first).
    static func compute<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes { crc = update(crc, with: byte) }
        return crc ^ 0xFFFF
    }

    /// The two bytes appended to a payload on the air, least significant first.
    static func fcsBytes<S: Sequence>(for payload: S) -> (UInt8, UInt8) where S.Element == UInt8 {
        let fcs = compute(payload)
        return (UInt8(fcs & 0xFF), UInt8(fcs >> 8))
    }

    /// Whether `payload + FCS` is intact: the running register equals `goodResidue`.
    static func verify<C: Collection>(frameWithFCS bytes: C) -> Bool where C.Element == UInt8 {
        guard bytes.count >= 3 else { return false }
        var crc: UInt16 = 0xFFFF
        for byte in bytes { crc = update(crc, with: byte) }
        return crc == goodResidue
    }
}
