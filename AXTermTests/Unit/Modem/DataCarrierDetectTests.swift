import XCTest
@testable import AXTerm

/// Carrier detect follows the decoder, holds briefly, and ignores whispers.
final class DataCarrierDetectTests: XCTestCase {

    func testFlagsAssertAndHold() {
        var dcd = DataCarrierDetect(holdSamples: 2400)
        XCTAssertFalse(dcd.update(activity: .idle, rmsDBFS: -20, squelchDBFS: -50, now: 0))
        XCTAssertTrue(dcd.update(activity: .flags, rmsDBFS: -20, squelchDBFS: -50, now: 100))
        XCTAssertTrue(dcd.update(activity: .idle, rmsDBFS: -60, squelchDBFS: -50, now: 100 + 2400), "held")
        XCTAssertFalse(dcd.update(activity: .idle, rmsDBFS: -60, squelchDBFS: -50, now: 100 + 2401), "released")
    }

    func testDataAssertsToo() {
        var dcd = DataCarrierDetect(holdSamples: 100)
        XCTAssertTrue(dcd.update(activity: .inFrame, rmsDBFS: -10, squelchDBFS: -50, now: 5))
    }

    func testNothingBelowTheSquelchFloorCounts() {
        var dcd = DataCarrierDetect(holdSamples: 100)
        XCTAssertFalse(dcd.update(activity: .flags, rmsDBFS: -55, squelchDBFS: -50, now: 0))
        XCTAssertFalse(dcd.isDetected)
    }

    func testResetClears() {
        var dcd = DataCarrierDetect(holdSamples: 100_000)
        _ = dcd.update(activity: .flags, rmsDBFS: -10, squelchDBFS: -50, now: 0)
        XCTAssertTrue(dcd.isDetected)
        dcd.reset()
        XCTAssertFalse(dcd.isDetected)
        XCTAssertFalse(dcd.update(activity: .idle, rmsDBFS: -10, squelchDBFS: -50, now: 10))
    }
}
