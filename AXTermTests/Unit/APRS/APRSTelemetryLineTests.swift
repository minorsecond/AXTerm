//
//  APRSTelemetryLineTests.swift
//  AXTermTests
//
//  A telemetry frame in words. The definitions are the ones NCFPD's
//  WX3in1Plus20 sends on 144.390.
//

import XCTest
@testable import AXTerm

final class APRSTelemetryLineTests: XCTestCase {

    /// The four messages a station sends to describe its own channels.
    private func wx3in1Definition() -> APRSTelemetry.Definition {
        var d = APRSTelemetry.Definition()
        for body in ["PARM.Vin,Rx1h,Dg1h,Eff1h,A5,O1,O2,O3,O4,I1,I2,I3,I4",
                     "UNIT.Volt,Pkt,Pkt,Pcnt,None,On,On,On,On,Hi,Hi,Hi,Hi",
                     "EQNS.0,0.075,0,0,10,0,0,10,0,0,1,0,0,0,0",
                     "BITS.11111111,WX3in1Plus20 Telemetry"] {
            XCTAssertTrue(APRSTelemetry.parseDefinition(body, into: &d), body)
        }
        return d
    }

    private func digest(_ info: String) -> APRSDigest? {
        APRSDigest.parse(destination: "APMI06", info: Data(info.utf8))
    }

    /// Without the definitions there is nothing to name the channels with, so
    /// the line says the numbers and nothing more.
    func testWithoutADefinitionTheCountsStayCounts() throws {
        let d = try XCTUnwrap(digest("T#084,137,140,041,000,000,00010011"))
        let line = APRSDigestLine.text(for: d)
        XCTAssertTrue(line.contains("Telemetry #084"), line)
        XCTAssertTrue(line.contains("137, 140, 41, 0, 0"), line)
        XCTAssertTrue(line.contains("bits 00010011"), line)
    }

    /// With them, every channel is named, calibrated and given its unit — and
    /// the digital lines stop being eight anonymous ones and zeros.
    func testWithADefinitionEveryChannelIsNamed() throws {
        let d = try XCTUnwrap(digest("T#084,137,140,041,000,000,00010011"))
        let line = APRSDigestLine.text(for: d, definition: wx3in1Definition())

        XCTAssertTrue(line.contains("WX3in1Plus20 Telemetry"), "the project title from BITS: \(line)")
        // Vin: a = 0, b = 0.075, c = 0 — so 137 counts is 10.275 V.
        XCTAssertTrue(line.contains("Vin 10.27 Volt") || line.contains("Vin 10.28 Volt"),
                      "the EQNS quadratic has to be applied: \(line)")
        // Rx1h has b = 10, so 140 counts is 1400 packets — the calibration is
        // the whole point, and a line reporting "140 Pkt" would be wrong by a
        // factor of ten.
        XCTAssertTrue(line.contains("Rx1h 1400 Pkt"), line)
        XCTAssertTrue(line.contains("Dg1h 410 Pkt"), line)
        XCTAssertTrue(line.contains("Eff1h 0 Pcnt"), line)

        XCTAssertFalse(line.contains("bits "), "named lines replace the bit string: \(line)")
        // 00010011 against O1,O2,O3,O4,I1,I2,I3,I4 in order.
        XCTAssertTrue(line.contains("O1 off"), line)
        XCTAssertTrue(line.contains("O4 on"), line)
        XCTAssertTrue(line.contains("I1 off"), line)
        XCTAssertTrue(line.contains("I3 on"), line)
        XCTAssertTrue(line.contains("I4 on"), line)
    }

    /// `Reading.text` refuses to print an uncalibrated count in units it has
    /// not earned — a raw 137 shown as "137 Volt" would be a fabrication, and
    /// a flood gauge is the worst place to make one.
    func testAChannelWithNoEquationIsMarkedARawCount() throws {
        var partial = APRSTelemetry.Definition()
        XCTAssertTrue(APRSTelemetry.parseDefinition("PARM.Vin,Rx1h", into: &partial))
        XCTAssertTrue(APRSTelemetry.parseDefinition("UNIT.Volt,Pkt", into: &partial))

        let d = try XCTUnwrap(digest("T#084,137,140,041,000,000,00000000"))
        let line = APRSDigestLine.text(for: d, definition: partial)
        XCTAssertTrue(line.contains("(raw)"), "named but uncalibrated stays a count: \(line)")
        XCTAssertFalse(line.contains("137 Volt"), line)
    }

    /// A station that names none of its digital lines keeps the bit string:
    /// eight "channel six is off" would say less than `00010011` does.
    func testUnnamedDigitalLinesKeepTheBitString() throws {
        var analogueOnly = APRSTelemetry.Definition()
        XCTAssertTrue(APRSTelemetry.parseDefinition("PARM.Vin", into: &analogueOnly))

        let d = try XCTUnwrap(digest("T#084,137,140,041,000,000,00010011"))
        XCTAssertTrue(APRSDigestLine.text(for: d, definition: analogueOnly).contains("bits 00010011"))
    }
}
