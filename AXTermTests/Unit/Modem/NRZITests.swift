import XCTest
@testable import AXTerm

/// NRZI: a 0 changes the level, a 1 holds it — and nothing else matters.
final class NRZITests: XCTestCase {

    private func roundTrip(_ bits: [Bool], invert: Bool = false, initialLevel: Bool = false) -> [Bool] {
        var encoder = NRZIEncoder(initialLevel: initialLevel)
        var decoder = NRZIDecoder()
        // The decoder's first level has nothing before it; prime it with the
        // idle level, as a real line would.
        _ = decoder.decode(level: initialLevel != invert)
        return bits.map { bit in
            let level = encoder.encode(bit: bit)
            return decoder.decode(level: level != invert)
        }
    }

    func testEncodeThenDecodeIsIdentity() {
        var rng = SystemRandomNumberGenerator()
        let bits = (0..<2000).map { _ in Bool.random(using: &rng) }
        XCTAssertEqual(roundTrip(bits), bits)
    }

    /// Only changes carry information, so an inverted line decodes the same.
    func testAnInvertedLineDecodesIdentically() {
        var rng = SystemRandomNumberGenerator()
        let bits = (0..<2000).map { _ in Bool.random(using: &rng) }
        XCTAssertEqual(roundTrip(bits, invert: true), bits)
    }

    func testTheStartingLevelDoesNotMatter() {
        let bits: [Bool] = [true, false, false, true, true, true, false]
        XCTAssertEqual(roundTrip(bits, initialLevel: false), bits)
        XCTAssertEqual(roundTrip(bits, initialLevel: true), bits)
    }

    func testAZeroTogglesAndAOneHolds() {
        var encoder = NRZIEncoder()
        XCTAssertEqual(encoder.encode(bit: true), false)
        XCTAssertEqual(encoder.encode(bit: false), true)
        XCTAssertEqual(encoder.encode(bit: false), false)
        XCTAssertEqual(encoder.encode(bit: true), false)
    }

    func testTheVeryFirstLevelReadsAsAOne() {
        var decoder = NRZIDecoder()
        XCTAssertTrue(decoder.decode(level: true))
        XCTAssertTrue(decoder.decode(level: true))
        XCTAssertFalse(decoder.decode(level: false))
    }
}
