import XCTest
@testable import AXTerm

/// The AX.25 frame check sequence, pinned to its published constants.
final class CRC16X25Tests: XCTestCase {

    func testPublishedCheckValue() {
        XCTAssertEqual(CRC16X25.compute(Array("123456789".utf8)), 0x906E)
    }

    func testEmptyPayloadHasAKnownFCS() {
        // Init 0xFFFF, no bytes, complemented.
        XCTAssertEqual(CRC16X25.compute([UInt8]()), 0x0000)
    }

    func testFCSBytesAreLeastSignificantFirst() {
        let (lo, hi) = CRC16X25.fcsBytes(for: Array("123456789".utf8))
        XCTAssertEqual(lo, 0x6E)
        XCTAssertEqual(hi, 0x90)
    }

    /// Payload plus its FCS always leaves the good residue in the register.
    func testVerifyAcceptsPayloadPlusFCSByResidue() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<1000 {
            let payload = (0..<Int.random(in: 1...300, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let (lo, hi) = CRC16X25.fcsBytes(for: payload)
            XCTAssertTrue(CRC16X25.verify(frameWithFCS: payload + [lo, hi]))
        }
    }

    func testVerifyRejectsAnyBitFlip() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var frame = (0..<Int.random(in: 1...200, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let (lo, hi) = CRC16X25.fcsBytes(for: frame)
            frame += [lo, hi]
            let index = Int.random(in: 0..<frame.count, using: &rng)
            frame[index] ^= UInt8(1 << Int.random(in: 0...7, using: &rng))
            XCTAssertFalse(CRC16X25.verify(frameWithFCS: frame))
        }
    }

    func testVerifyNeedsAtLeastOneByteBesidesTheFCS() {
        XCTAssertFalse(CRC16X25.verify(frameWithFCS: [0x00, 0x00]))
        XCTAssertFalse(CRC16X25.verify(frameWithFCS: [UInt8]()))
    }

    /// An AX.25 UI frame built by the app carries the FCS a TNC would put
    /// on it; the modem's encoder must agree with the rest of the world.
    func testAnAX25UIFrameRoundTrips() {
        let frame = AX25FrameBuilder.buildUI(
            from: AX25Address(call: "K0EPI", ssid: 7),
            to: AX25Address(call: "CQ", ssid: 0),
            via: DigiPath(), pid: 0xF0, payload: Data("hello".utf8), displayInfo: "hello")
        let bytes = [UInt8](frame.encodeAX25())
        let (lo, hi) = CRC16X25.fcsBytes(for: bytes)
        XCTAssertTrue(CRC16X25.verify(frameWithFCS: bytes + [lo, hi]))
        XCTAssertFalse(CRC16X25.verify(frameWithFCS: bytes + [hi, lo]), "byte order matters")
    }
}
