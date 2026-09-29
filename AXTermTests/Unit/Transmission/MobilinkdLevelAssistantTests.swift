import XCTest
@testable import AXTerm

final class MobilinkdLevelAssistantTests: XCTestCase {

    private func level(_ fraction: Double, clipped: Bool = false) -> MobilinkdInputLevel {
        let vpp = UInt16(fraction * 65_535)
        let mid: UInt16 = 32_768
        return MobilinkdInputLevel(vpp: vpp, vavg: mid,
                                   vmin: clipped ? 0 : mid - vpp / 2,
                                   vmax: clipped ? 65_472 : mid + vpp / 2)
    }
    private func readings(_ fraction: Double, clipped: Bool = false) -> [MobilinkdInputLevel] {
        Array(repeating: level(fraction, clipped: clipped), count: 10)
    }

    /// The lowest gain that works wins: less gain recovers sooner after transmitting.
    func testStopsAtTheFirstGoodGain() {
        var a = MobilinkdLevelAssistant()
        XCTAssertEqual(a.step, .measure(gain: 0))
        XCTAssertEqual(a.record(readings(0.05)), .measure(gain: 1))
        XCTAssertEqual(a.record(readings(0.45)), .done(gain: 1))
    }

    func testClippingAtTheBottomMeansTheRadioIsTooLoud() {
        var a = MobilinkdLevelAssistant()
        XCTAssertEqual(a.record(readings(1.0, clipped: true)), .radioTooLoud)
    }

    func testQuietAtTheTopMeansTheRadioIsTooQuiet() {
        var a = MobilinkdLevelAssistant()
        for _ in 0..<4 { a.record(readings(0.02)) }
        XCTAssertEqual(a.record(readings(0.1)), .radioTooQuiet(bestGain: 4))
    }

    func testTooQuietThenClippingIsBetweenSteps() {
        var a = MobilinkdLevelAssistant()
        a.record(readings(0.2))
        XCTAssertEqual(a.record(readings(1.0, clipped: true)), .betweenSteps(quieterGain: 0))
    }

    /// Measured on 2026-09-29: IC-V8 at volume 2, gain 4, open squelch.
    func testARealGoodReading() {
        let real = MobilinkdInputLevel(vpp: 48012, vavg: 35216, vmin: 10744, vmax: 58756)
        XCTAssertEqual(MobilinkdLevelAssistant.judge([real]), .good)
        let clipping = MobilinkdInputLevel(vpp: 65476, vavg: 35664, vmin: 0, vmax: 65476)
        XCTAssertEqual(MobilinkdLevelAssistant.judge([clipping]), .clipping)
    }

    /// One spike doesn't make a clip.
    func testASingleSpikeIsTolerated() {
        var r = readings(0.5)
        r[3] = level(1.0, clipped: true)
        XCTAssertEqual(MobilinkdLevelAssistant.judge(r), .good)
    }

    func testNoReadingsChangesNothing() {
        var a = MobilinkdLevelAssistant()
        XCTAssertEqual(a.record([]), .measure(gain: 0))
    }
}
