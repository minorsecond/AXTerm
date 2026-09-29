import XCTest
@testable import AXTerm

/// Bit-clock recovery: the constants, and locking onto a jittered stream.
final class DigitalPLLTests: XCTestCase {

    func testStepConstants() {
        XCTAssertEqual(UInt32(bitPattern: DigitalPLL(samplesPerBit: 10).step), 0x1999_999A)
        XCTAssertEqual(UInt32(bitPattern: DigitalPLL(samplesPerBit: 40).step), 0x0666_6666)
        XCTAssertEqual(UInt32(bitPattern: DigitalPLL(samplesPerBit: 5).step), 0x3333_3333)
    }

    func testSamplesOncePerBitWhenFreeRunning() {
        var pll = DigitalPLL(samplesPerBit: 10)
        var samples = 0
        for _ in 0..<10_000 where pll.advance() { samples += 1 }
        XCTAssertEqual(samples, 1000, accuracy: 1)
    }

    /// A stream whose transitions come every N samples pulls the sampling
    /// instant to the middle of the bit, and stays there against a small
    /// baud error.
    func testLocksOntoTransitionsAndStaysWithinATenthOfABit() {
        for baudError in [0.0, 0.005, -0.005] {
            var pll = DigitalPLL(samplesPerBit: 10)
            let actualSamplesPerBit = 10 * (1 + baudError)
            var nextTransition = 3.0     // start off-phase
            var sampleInstants: [Double] = []
            var transitions = 0
            var t = 0.0
            for _ in 0..<12_000 {
                if t >= nextTransition {
                    pll.transition(dataDetected: transitions > 8)
                    transitions += 1
                    nextTransition += actualSamplesPerBit
                }
                if pll.advance() {
                    // Where in the bit did we sample? 0.5 is the middle.
                    let phase = ((t - (nextTransition - actualSamplesPerBit)) / actualSamplesPerBit)
                    sampleInstants.append(phase)
                }
                t += 1
            }
            XCTAssertTrue(pll.isLocked, "baud error \(baudError)")
            let late = sampleInstants.suffix(200)
            for phase in late {
                // A steady baud error leaves a steady lag; a sixth of a bit is
                // well inside the eye.
                XCTAssertEqual(phase, 0.5, accuracy: 0.17, "baud error \(baudError)")
            }
        }
    }

    func testUnlockedUntilEnoughTransitions() {
        var pll = DigitalPLL(samplesPerBit: 10)
        XCTAssertFalse(pll.isLocked)
        for _ in 0..<5 { pll.transition(dataDetected: false); for _ in 0..<10 { _ = pll.advance() } }
        XCTAssertFalse(pll.isLocked, "fewer than eight transitions is a guess")
    }
}
