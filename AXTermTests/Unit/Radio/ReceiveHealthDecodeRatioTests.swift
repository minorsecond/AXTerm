import XCTest
@testable import AXTerm

/// A sound-modem radio that hears traffic and decodes little of it, the
/// shape of the 2026-09-30 notch failure: an idle channel and a healthy one
/// must never be flagged, and the counts must come from the last ten
/// minutes, not from whenever the link came up.
final class ReceiveHealthDecodeRatioTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - The rule

    func testAnIdleChannelSaysNothing() {
        XCTAssertNil(ReceiveHealth.decodeRatio(carriers: 0, decoded: 0, minutes: 10, radioSays: nil))
        XCTAssertNil(ReceiveHealth.decodeRatio(carriers: 9, decoded: 0, minutes: 10, radioSays: nil),
                     "nine transmissions are not enough to judge by")
    }

    func testAHealthyChannelSaysNothing() {
        XCTAssertNil(ReceiveHealth.decodeRatio(carriers: 40, decoded: 35, minutes: 10, radioSays: nil))
        XCTAssertNil(ReceiveHealth.decodeRatio(carriers: 40, decoded: 10, minutes: 10, radioSays: nil),
                     "exactly a quarter is not below a quarter")
        XCTAssertNil(ReceiveHealth.decodeRatio(carriers: 12, decoded: 30, minutes: 10, radioSays: nil),
                     "more frames than transmissions (several per carrier) is fine")
    }

    func testANotchLikeChannelIsFlagged() {
        XCTAssertEqual(ReceiveHealth.decodeRatio(carriers: 40, decoded: 9, minutes: 10, radioSays: nil),
                       .hearsButDecodesLittle(carriers: 40, decoded: 9, minutes: 10, radioSays: nil))
        XCTAssertEqual(ReceiveHealth.decodeRatio(carriers: 10, decoded: 0, minutes: 4, radioSays: []),
                       .hearsButDecodesLittle(carriers: 10, decoded: 0, minutes: 4, radioSays: []))
    }

    func testTheThresholdsAreTheSpecs() {
        XCTAssertEqual(ReceiveHealth.minimumCarriers, 10)
        XCTAssertEqual(ReceiveHealth.minimumDecodeRatio, 0.25)
        XCTAssertEqual(ReceiveHealth.carrierWindow, 600)
    }

    // MARK: - The message

    func testWithoutCIVTheMessageGivesTheGenericList() {
        let m = ReceiveHealth.message(.hearsButDecodesLittle(carriers: 23, decoded: 3, minutes: 10, radioSays: nil))
        XCTAssertEqual(m, "Heard 23 transmissions in 10 min but decoded 3 frames. "
                       + "Check the radio's notch, noise reduction, filters and audio level.")
    }

    func testWithCIVTheMessageNamesWhatTheRadioSays() {
        let m = ReceiveHealth.message(.hearsButDecodesLittle(
            carriers: 23, decoded: 1, minutes: 10, radioSays: ["The auto notch is on", "Noise reduction is on"]))
        XCTAssertEqual(m, "Heard 23 transmissions in 10 min but decoded 1 frame. "
                       + "The radio reports: the auto notch is on, noise reduction is on.")
    }

    func testWithCIVAndACleanAuditTheMessageSaysSo() {
        let m = ReceiveHealth.message(.hearsButDecodesLittle(carriers: 23, decoded: 2, minutes: 10, radioSays: []))
        XCTAssertTrue(m.contains("receive settings look right"), m)
        XCTAssertFalse(m.contains("\u{2014}"))
    }

    // MARK: - The ledger

    private func feed(_ ledger: inout ReceiveHealth.CarrierLedger,
                      from start: Double, to end: Double, step: Double = 1,
                      carriers: (Double) -> UInt64, decoded: (Double) -> UInt64) {
        var t = start
        while t <= end {
            ledger.record(at: at(t), carriers: carriers(t), decoded: decoded(t))
            t += step
        }
    }

    func testNothingRecordedIsNothing() {
        XCTAssertNil(ReceiveHealth.CarrierLedger().counts(now: t0))
    }

    func testCountsSinceTheFirstSampleBeforeTheWindowFills() throws {
        var ledger = ReceiveHealth.CarrierLedger()
        ledger.record(at: at(0), carriers: 100, decoded: 50)
        ledger.record(at: at(120), carriers: 112, decoded: 51)
        let c = try XCTUnwrap(ledger.counts(now: at(120)))
        XCTAssertEqual(c.carriers, 12)
        XCTAssertEqual(c.decoded, 1)
        XCTAssertEqual(c.minutes, 2)
    }

    /// Twenty minutes of a steady channel: only the last ten count.
    func testTheWindowRollsOver() throws {
        var ledger = ReceiveHealth.CarrierLedger()
        // Four carriers a minute, one decode a minute, for twenty minutes.
        feed(&ledger, from: 0, to: 1200, carriers: { UInt64($0 / 15) }, decoded: { UInt64($0 / 60) })
        let c = try XCTUnwrap(ledger.counts(now: at(1200)))
        XCTAssertEqual(c.carriers, 40, accuracy: 1)
        XCTAssertEqual(c.decoded, 10, accuracy: 1)
        XCTAssertEqual(c.minutes, 10)
        XCTAssertLessThanOrEqual(ledger.history.count, 125, "bounded by the spacing")
    }

    /// A burst of undecoded carriers eleven minutes ago has left the window;
    /// one nine minutes ago has not.
    func testABurstAtTheWindowEdge() throws {
        func carriers(burstAt: Double) -> (Double) -> UInt64 { { $0 >= burstAt ? 20 : 0 } }
        var old = ReceiveHealth.CarrierLedger()
        feed(&old, from: 0, to: 1320, step: 5, carriers: carriers(burstAt: 660), decoded: { _ in 0 })
        let oldCounts = try XCTUnwrap(old.counts(now: at(1320)))
        XCTAssertEqual(oldCounts.carriers, 0, "the burst at 11 min is outside the last 10")
        XCTAssertNil(ReceiveHealth.decodeRatio(carriers: oldCounts.carriers, decoded: 0, minutes: 10, radioSays: nil))

        var recent = ReceiveHealth.CarrierLedger()
        feed(&recent, from: 0, to: 1320, step: 5, carriers: carriers(burstAt: 780), decoded: { _ in 0 })
        let recentCounts = try XCTUnwrap(recent.counts(now: at(1320)))
        XCTAssertEqual(recentCounts.carriers, 20, "the burst at 9 min before now is inside")
        XCTAssertNotNil(ReceiveHealth.decodeRatio(carriers: recentCounts.carriers, decoded: 0, minutes: 10, radioSays: nil))
    }

    /// Exactly on the boundary: the baseline is the last sample at or
    /// before the window's start, so a carrier counted after it is inside.
    func testTheBoundarySampleIsTheBaseline() throws {
        var ledger = ReceiveHealth.CarrierLedger()
        ledger.record(at: at(0), carriers: 0, decoded: 0)
        ledger.record(at: at(600), carriers: 5, decoded: 0)
        ledger.record(at: at(1200), carriers: 17, decoded: 1)
        let c = try XCTUnwrap(ledger.counts(now: at(1200)))
        XCTAssertEqual(c.carriers, 12)
        XCTAssertEqual(c.decoded, 1)
    }

    /// The modem restarted and its counters went back to zero. What came
    /// before is not evidence about the new session.
    func testARestartedModemStartsAFreshLedger() throws {
        var ledger = ReceiveHealth.CarrierLedger()
        ledger.record(at: at(0), carriers: 500, decoded: 20)
        ledger.record(at: at(60), carriers: 520, decoded: 21)
        ledger.record(at: at(120), carriers: 3, decoded: 2)
        XCTAssertNil(ledger.counts(now: at(120)), "one sample since the restart is nothing to compare")
        ledger.record(at: at(180), carriers: 5, decoded: 2)
        let c = try XCTUnwrap(ledger.counts(now: at(180)))
        XCTAssertEqual(c.carriers, 2)
    }

    /// Reports arrive ten times a second; the ledger keeps the latest for
    /// the counts but files history only every few seconds.
    func testRapidReportsAreThinned() throws {
        var ledger = ReceiveHealth.CarrierLedger()
        feed(&ledger, from: 0, to: 60, step: 0.1, carriers: { UInt64($0) }, decoded: { _ in 0 })
        XCTAssertLessThanOrEqual(ledger.history.count, 13)
        let c = try XCTUnwrap(ledger.counts(now: at(60)))
        XCTAssertEqual(c.carriers, 60, accuracy: 1, "the newest report counts even between filings")
    }

    // MARK: - End to end on counts

    /// Idle, healthy and notch-like channels as a modem would report them.
    func testThreeChannels() throws {
        func verdict(carriersPerMinute: Double, decodesPerMinute: Double) throws -> ReceiveHealth.Verdict? {
            var ledger = ReceiveHealth.CarrierLedger()
            feed(&ledger, from: 0, to: 900, step: 1,
                 carriers: { UInt64($0 / 60 * carriersPerMinute) },
                 decoded: { UInt64($0 / 60 * decodesPerMinute) })
            let c = try XCTUnwrap(ledger.counts(now: at(900)))
            return ReceiveHealth.decodeRatio(carriers: c.carriers, decoded: c.decoded, minutes: c.minutes, radioSays: nil)
        }
        XCTAssertNil(try verdict(carriersPerMinute: 0.3, decodesPerMinute: 0), "idle: 3 in 10 min")
        XCTAssertNil(try verdict(carriersPerMinute: 5, decodesPerMinute: 4.7), "healthy: 14 of 17 in 3 min, scaled")
        XCTAssertNotNil(try verdict(carriersPerMinute: 5, decodesPerMinute: 1), "notch: about one a minute")
    }
}
