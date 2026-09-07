import XCTest
@testable import AXTerm

/// Properties of the cross-radio fold that no single example pins: the
/// answer must not depend on which radio heard a frame first, a frame that
/// differs by any bit is never folded, and outside the window nothing is.
final class CrossRadioDedupPropertyTests: XCTestCase {

    private let a = RadioID(rawValue: "a")
    private let b = RadioID(rawValue: "b")
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func randomFrame(_ rng: inout SystemRandomNumberGenerator) -> Data {
        Data((0..<Int.random(in: 16...80, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    /// A then B and B then A both fold exactly one copy, whichever radio
    /// was first — the fold names the first radio, but the count is the same.
    func testOrderOfHearingDoesNotChangeWhatIsFolded() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let frame = randomFrame(&rng)
            let gap = TimeInterval.random(in: 0...(CrossRadioDedup.defaultWindow - 0.01), using: &rng)
            var ab = CrossRadioDedup()
            var ba = CrossRadioDedup()
            let abResults = [ab.admit(raw: frame, radio: a, at: t0), ab.admit(raw: frame, radio: b, at: t0.addingTimeInterval(gap))]
            let baResults = [ba.admit(raw: frame, radio: b, at: t0), ba.admit(raw: frame, radio: a, at: t0.addingTimeInterval(gap))]
            XCTAssertEqual(abResults[0], .first)
            XCTAssertEqual(abResults[1], .additionalRadio(firstRadio: a))
            XCTAssertEqual(baResults[0], .first)
            XCTAssertEqual(baResults[1], .additionalRadio(firstRadio: b))
        }
    }

    /// Flip any one bit — a digipeater's has-been-repeated bit, a corrupted
    /// byte, a different SSID — and it is another frame, never folded.
    func testAnyBitDifferenceIsNeverFolded() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let frame = randomFrame(&rng)
            var flipped = frame
            let index = Int.random(in: 0..<frame.count, using: &rng)
            flipped[index] ^= UInt8(1 << Int.random(in: 0...7, using: &rng))
            var dedup = CrossRadioDedup()
            XCTAssertEqual(dedup.admit(raw: frame, radio: a, at: t0), .first)
            XCTAssertEqual(dedup.admit(raw: flipped, radio: b, at: t0.addingTimeInterval(0.1)), .first)
        }
    }

    /// A random stream where every frame is unique, or repeated only past
    /// the window, is admitted whole: the fold never eats a real frame.
    func testNothingIsFoldedOutsideTheWindow() {
        var rng = SystemRandomNumberGenerator()
        var dedup = CrossRadioDedup()
        var when = t0
        var seen: [Data] = []
        for i in 0..<500 {
            let frame: Data
            if i % 5 == 4, let old = seen.randomElement(using: &rng) {
                frame = old  // a repeat, but the window has long passed
            } else {
                frame = randomFrame(&rng)
                seen.append(frame)
            }
            when = when.addingTimeInterval(CrossRadioDedup.defaultWindow + 0.01)
            let radio = Bool.random(using: &rng) ? a : b
            XCTAssertEqual(dedup.admit(raw: frame, radio: radio, at: when), .first, "frame \(i)")
        }
    }

    /// Counting: over any sequence of (frame, radio, time), the number of
    /// packets the app would log equals the number of distinct
    /// transmissions — one per frame per window, however many radios heard it.
    func testFoldsPlusFirstsEqualHearingsAndFirstsEqualTransmissions() {
        var rng = SystemRandomNumberGenerator()
        var dedup = CrossRadioDedup()
        var firsts = 0, folds = 0, transmissions = 0, hearings = 0
        var when = t0
        for _ in 0..<200 {
            when = when.addingTimeInterval(CrossRadioDedup.defaultWindow + 0.01)
            let frame = randomFrame(&rng)
            transmissions += 1
            // Heard by A, by B, or by both inside the window.
            let radios: [RadioID] = [[a], [b], [a, b], [b, a]].randomElement(using: &rng)!
            for (offset, radio) in radios.enumerated() {
                hearings += 1
                switch dedup.admit(raw: frame, radio: radio, at: when.addingTimeInterval(Double(offset) * 0.2)) {
                case .first: firsts += 1
                case .additionalRadio: folds += 1
                case .sameRadioRepeat: XCTFail("distinct radios never repeat here")
                }
            }
        }
        XCTAssertEqual(firsts, transmissions, "one packet per transmission")
        XCTAssertEqual(firsts + folds, hearings, "every hearing is either the packet or a fold")
    }
}
