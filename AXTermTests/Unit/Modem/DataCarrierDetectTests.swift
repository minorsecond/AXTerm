import XCTest
@testable import AXTerm

/// Carrier detect follows tone separation, holds briefly, and ignores whispers.
final class DataCarrierDetectTests: XCTestCase {

    private let signal: Float = 0.9      // one tone clearly present
    private let noise: Float = 0.45      // two equal powers: an empty channel

    func testAToneAssertsAndHolds() {
        var dcd = DataCarrierDetect(holdSamples: 2400)
        XCTAssertFalse(dcd.update(discrimination: noise, rmsDBFS: -20, squelchDBFS: -50, now: 0))
        XCTAssertTrue(dcd.update(discrimination: signal, rmsDBFS: -20, squelchDBFS: -50, now: 100))
        XCTAssertTrue(dcd.update(discrimination: noise, rmsDBFS: -20, squelchDBFS: -50,
                                 now: 100 + 2400), "held")
        XCTAssertFalse(dcd.update(discrimination: noise, rmsDBFS: -20, squelchDBFS: -50,
                                  now: 100 + 2401), "released")
    }

    func testNothingBelowTheSquelchFloorCounts() {
        var dcd = DataCarrierDetect(holdSamples: 100)
        XCTAssertFalse(dcd.update(discrimination: signal, rmsDBFS: -55, squelchDBFS: -50, now: 0))
        XCTAssertFalse(dcd.isDetected)
    }

    func testResetClears() {
        var dcd = DataCarrierDetect(holdSamples: 100_000)
        _ = dcd.update(discrimination: signal, rmsDBFS: -10, squelchDBFS: -50, now: 0)
        XCTAssertTrue(dcd.isDetected)
        dcd.reset()
        XCTAssertFalse(dcd.isDetected)
        XCTAssertFalse(dcd.update(discrimination: noise, rmsDBFS: -10, squelchDBFS: -50, now: 10))
    }

    /// The regression that made the radio untransmittable: an open squelch
    /// feeds noise continuously and well above the level floor, and that must
    /// not read as a busy channel. Noise's tone discrimination measures 0.45
    /// on average and never exceeded 0.56 over a minute of it.
    func testAnOpenSquelchIsNotACarrier() {
        var dcd = DataCarrierDetect(holdSamples: 4000)
        for step in 0..<1000 {
            let wobble = Float(step % 7) * 0.015          // 0.45 … 0.54
            XCTAssertFalse(dcd.update(discrimination: noise + wobble,
                                      rmsDBFS: -20, squelchDBFS: -90,
                                      now: Int64(step) * 256),
                           "loud noise on an open squelch read as a busy channel")
        }
    }
}

/// Carrier detect while somebody else is mid-transmission.
///
/// The failure this guards against is transmitting on top of another station:
/// the HDLC decoder falls back to `.idle` whenever frame sync breaks, and
/// carrier detect that followed it reported a clear channel in the middle of
/// other people's frames, which is all `ChannelAccess` needs to start its slot
/// countdown and key.
final class DataCarrierDetectLockTests: XCTestCase {

    /// Tone separation does not depend on framing or bit sync, so it survives
    /// exactly the sync losses that used to release the channel.
    func testTheChannelStaysBusyWhileFrameSyncIsLost() {
        var dcd = DataCarrierDetect(holdSamples: 100)
        XCTAssertTrue(dcd.update(discrimination: 0.9, rmsDBFS: -20, squelchDBFS: -50, now: 0))
        // Sync breaks — a fade, a collision, a burst of noise — but the tones
        // are still there and the station is still transmitting.
        XCTAssertTrue(dcd.update(discrimination: 0.85, rmsDBFS: -20, squelchDBFS: -50,
                                 now: 5_000),
                      "still busy: one tone is still plainly present")
    }

    /// Once the signal really has gone, the hold expires and not before.
    func testTheChannelClearsOnlyAfterTheHold() {
        var dcd = DataCarrierDetect(holdSamples: 100)
        _ = dcd.update(discrimination: 0.9, rmsDBFS: -20, squelchDBFS: -50, now: 0)
        XCTAssertTrue(dcd.update(discrimination: 0.4, rmsDBFS: -60, squelchDBFS: -50,
                                 now: 100), "held")
        XCTAssertFalse(dcd.update(discrimination: 0.4, rmsDBFS: -60, squelchDBFS: -50,
                                  now: 101), "released")
    }
}
