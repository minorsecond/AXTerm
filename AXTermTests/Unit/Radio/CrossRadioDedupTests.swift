import XCTest
@testable import AXTerm

/// One transmission heard by two radios is one packet.
final class CrossRadioDedupTests: XCTestCase {

    private let a = RadioID(rawValue: "a")
    private let b = RadioID(rawValue: "b")
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let frame = Data([0x02, 0xA0, 0xA4, 0x03, 0xF0, 0x41])

    func testTheSecondRadiosCopyInsideTheWindowIsFolded() {
        var dedup = CrossRadioDedup()
        XCTAssertEqual(dedup.admit(raw: frame, radio: a, at: t0), .first)
        XCTAssertEqual(dedup.admit(raw: frame, radio: b, at: t0.addingTimeInterval(0.4)),
                       .additionalRadio(firstRadio: a))
    }

    /// Outside the window the same bytes are a new transmission — a beacon
    /// repeated a minute later says the same thing twice on purpose.
    func testTheSameBytesOutsideTheWindowAreANewTransmission() {
        var dedup = CrossRadioDedup()
        XCTAssertEqual(dedup.admit(raw: frame, radio: a, at: t0), .first)
        XCTAssertEqual(dedup.admit(raw: frame, radio: b, at: t0.addingTimeInterval(1.6)), .first)
    }

    /// The same radio again is not this stage's business: the per-radio
    /// duplicate tracker decides whether that was an ingestion artefact or a
    /// retry, and it must keep seeing them.
    func testTheSameRadioAgainIsLeftToTheRetryTracker() {
        var dedup = CrossRadioDedup()
        XCTAssertEqual(dedup.admit(raw: frame, radio: a, at: t0), .first)
        XCTAssertEqual(dedup.admit(raw: frame, radio: a, at: t0.addingTimeInterval(0.5)), .sameRadioRepeat)
    }

    /// A digipeated copy differs by its has-been-repeated bit: two air
    /// events, two packets.
    func testADigipeatedCopyIsNotFolded() {
        var dedup = CrossRadioDedup()
        var repeated = frame
        // The digipeater's has-been-repeated bit, on a byte where it was clear.
        repeated[0] = repeated[0] | 0x80
        XCTAssertEqual(dedup.admit(raw: frame, radio: a, at: t0), .first)
        XCTAssertEqual(dedup.admit(raw: repeated, radio: b, at: t0.addingTimeInterval(0.2)), .first)
    }

    /// The window sits between the ingestion-dedup window and the retry
    /// window, so a fold can never be mistaken for either.
    func testTheWindowSitsBetweenIngestionAndRetry() {
        XCTAssertGreaterThan(CrossRadioDedup.defaultWindow, LinkQualityConfig.default.ingestionDedupWindow)
        XCTAssertLessThan(CrossRadioDedup.defaultWindow, LinkQualityConfig.default.retryDuplicateWindow)
    }

    /// A third radio's copy folds too, and the first radio is still named.
    func testAThirdRadioFoldsOntoTheFirst() {
        var dedup = CrossRadioDedup()
        let c = RadioID(rawValue: "c")
        _ = dedup.admit(raw: frame, radio: a, at: t0)
        _ = dedup.admit(raw: frame, radio: b, at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(dedup.admit(raw: frame, radio: c, at: t0.addingTimeInterval(0.2)),
                       .additionalRadio(firstRadio: a))
    }

    /// Bounded: the oldest sightings go once the table is full.
    func testTheTableIsBounded() {
        var dedup = CrossRadioDedup()
        for i in 0..<(CrossRadioDedup.capacity + 10) {
            _ = dedup.admit(raw: Data([UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF)]), radio: a, at: t0)
        }
        // The very first frame has been dropped, so it is "first" again.
        XCTAssertEqual(dedup.admit(raw: Data([0, 0]), radio: b, at: t0), .first)
    }
}
