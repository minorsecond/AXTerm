import XCTest
@testable import AXTerm

/// Telemetry: how a river gauge, a tank level or a battery bank reaches APRS.
/// The rule that matters is that an uncalibrated count is never dressed up as
/// a measurement — a raw 137 shown as "137 feet" on a flood gauge is the worst
/// fabrication this app could make.
final class APRSTelemetryTests: XCTestCase {

    private func frame(_ text: String) -> APRSTelemetry.Frame? {
        APRSTelemetry.parseFrame(info: Data(text.utf8))
    }

    // MARK: - The report

    func testStandardFrame() throws {
        let parsed = try XCTUnwrap(frame("T#005,199,000,255,073,123,01101001"))
        XCTAssertEqual(parsed.sequence, "005")
        XCTAssertEqual(parsed.analogue, [199, 0, 255, 73, 123])
        XCTAssertEqual(parsed.bits, [false, true, true, false, true, false, false, true])
    }

    /// The digital byte is optional in practice and its absence must not throw
    /// away five good analogue readings.
    func testFrameWithoutTheDigitalByte() throws {
        let parsed = try XCTUnwrap(frame("T#012,010,020,030,040,050"))
        XCTAssertEqual(parsed.analogue, [10, 20, 30, 40, 50])
        XCTAssertTrue(parsed.bits.isEmpty)
    }

    /// Some stations send a non-numeric sequence. Keeping it verbatim rather
    /// than forcing it into an Int loses nothing and rejects nothing.
    func testNonNumericSequenceIsKept() throws {
        let parsed = try XCTUnwrap(frame("T#MIC,010,020,030,040,050,00000000"))
        XCTAssertEqual(parsed.sequence, "MIC")
    }

    func testMalformedFramesAreRejected() {
        XCTAssertNil(frame("T#005,199,000"), "too few channels")
        XCTAssertNil(frame("T#005,abc,000,255,073,123"), "non-numeric channel")
        XCTAssertNil(frame("!3959.13N/10515.42W#not telemetry"))
    }

    // MARK: - The definitions

    func testParameterAndUnitNames() {
        var definition = APRSTelemetry.Definition()
        XCTAssertTrue(APRSTelemetry.parseDefinition(
            "PARM.Creek,Battery,Solar,Temp,Spare,Pump,Gate", into: &definition))
        XCTAssertTrue(APRSTelemetry.parseDefinition(
            "UNIT.feet,volts,amps,degF", into: &definition))

        XCTAssertEqual(definition.names.prefix(3), ["Creek", "Battery", "Solar"])
        XCTAssertEqual(definition.units.first, "feet")
    }

    func testEquationsCalibrateTheCounts() {
        var definition = APRSTelemetry.Definition()
        XCTAssertTrue(APRSTelemetry.parseDefinition(
            "EQNS.0,0.1,0,0,0.05,10", into: &definition))
        XCTAssertEqual(definition.coefficients.count, 2)

        let parsed = APRSTelemetry.parseFrame(
            info: Data("T#001,100,100,000,000,000".utf8))!
        let readings = APRSTelemetry.readings(parsed, definition: definition)
        // Channel 0: 0·v² + 0.1·v + 0 = 10
        XCTAssertEqual(readings[0].value, 10, accuracy: 0.001)
        XCTAssertTrue(readings[0].isCalibrated)
        // Channel 1: 0.05·100 + 10 = 15
        XCTAssertEqual(readings[1].value, 15, accuracy: 0.001)
    }

    /// A partial calibration is still better than none, and stations do send
    /// them — so the channels it covers are calibrated and the rest stay raw.
    func testAPartialEquationSetCalibratesOnlyWhatItCovers() {
        var definition = APRSTelemetry.Definition()
        _ = APRSTelemetry.parseDefinition("EQNS.0,0.1,0", into: &definition)
        let parsed = APRSTelemetry.parseFrame(
            info: Data("T#001,100,100,100,100,100".utf8))!
        let readings = APRSTelemetry.readings(parsed, definition: definition)
        XCTAssertTrue(readings[0].isCalibrated)
        XCTAssertFalse(readings[1].isCalibrated)
        XCTAssertEqual(readings[1].value, 100, "uncalibrated channels keep their raw count")
    }

    func testBitsMessageCarriesTheTitle() {
        var definition = APRSTelemetry.Definition()
        XCTAssertTrue(APRSTelemetry.parseDefinition(
            "BITS.11111111,Creek Gauge N of Bridge", into: &definition))
        XCTAssertEqual(definition.title, "Creek Gauge N of Bridge")
    }

    func testUnrelatedMessagesAreNotDefinitions() {
        var definition = APRSTelemetry.Definition()
        XCTAssertFalse(APRSTelemetry.parseDefinition("Hello there", into: &definition))
        XCTAssertFalse(APRSTelemetry.parseDefinition("EQNS.notanumber", into: &definition))
    }

    // MARK: - Never dressing a count up as a measurement

    /// The rule this whole type exists to protect.
    func testAnUncalibratedReadingSaysItIsRaw() {
        let parsed = APRSTelemetry.parseFrame(
            info: Data("T#001,137,000,000,000,000".utf8))!
        let readings = APRSTelemetry.readings(parsed, definition: nil)
        XCTAssertEqual(readings[0].text, "137 (raw)")
        XCTAssertFalse(readings[0].isCalibrated)
        XCTAssertNil(readings[0].name)
    }

    /// A unit with no equation is still not a measurement: the station said
    /// what the channel measures but not how to convert it.
    func testAUnitWithoutAnEquationIsStillRaw() {
        var definition = APRSTelemetry.Definition()
        _ = APRSTelemetry.parseDefinition("PARM.Creek", into: &definition)
        _ = APRSTelemetry.parseDefinition("UNIT.feet", into: &definition)
        let parsed = APRSTelemetry.parseFrame(
            info: Data("T#001,137,000,000,000,000".utf8))!
        let readings = APRSTelemetry.readings(parsed, definition: definition)
        XCTAssertEqual(readings[0].name, "Creek")
        XCTAssertEqual(readings[0].text, "137 (raw)",
                       "a named channel with no equation is still a count")
    }

    func testACalibratedReadingPrintsItsUnit() {
        var definition = APRSTelemetry.Definition()
        _ = APRSTelemetry.parseDefinition("PARM.Creek", into: &definition)
        _ = APRSTelemetry.parseDefinition("UNIT.feet", into: &definition)
        _ = APRSTelemetry.parseDefinition("EQNS.0,0.1,0", into: &definition)
        let parsed = APRSTelemetry.parseFrame(
            info: Data("T#001,137,000,000,000,000".utf8))!
        let readings = APRSTelemetry.readings(parsed, definition: definition)
        XCTAssertEqual(readings[0].text, "13.70 feet")
    }

    func testDigitalChannelsTakeTheirNamesAfterTheAnalogueOnes() {
        var definition = APRSTelemetry.Definition()
        _ = APRSTelemetry.parseDefinition(
            "PARM.A1,A2,A3,A4,A5,Pump,Gate", into: &definition)
        let parsed = APRSTelemetry.parseFrame(
            info: Data("T#001,0,0,0,0,0,10000000".utf8))!
        let bits = APRSTelemetry.bitReadings(parsed, definition: definition)
        XCTAssertEqual(bits[0].name, "Pump")
        XCTAssertTrue(bits[0].isOn)
        XCTAssertEqual(bits[1].name, "Gate")
        XCTAssertFalse(bits[1].isOn)
    }
}
