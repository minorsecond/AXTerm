//
//  ParkTestFormTests.swift
//  AXTermTests
//
//  The park field test as a form, filled in on the iPad and sent by Winlink
//  like the ICS forms, but filed apart from the official ones: it is
//  AXTerm's own, with no Winlink viewer behind it (operator, 2026-10-08).
//

import XCTest
@testable import AXTerm

final class ParkTestFormTests: XCTestCase {

    private let steps = ["P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8", "P9",
                         "M1", "M2", "I1", "I2", "I3", "R1"]

    private var context: WinlinkFormContext {
        WinlinkFormContext(
            callsign: "K0EPI", appVersion: "1.0",
            now: WinlinkB2Message.dateFormatter.date(from: "2026/10/09 17:00")!,
            location: StationLocation(latitude: 39.615928, longitude: -104.739856, gridSquare: "DM79po",
                                      source: .gps, timestamp: Date(timeIntervalSince1970: 0)),
            operatorName: "Ross Wardrup", operatorNameWithTitle: "Ross Wardrup",
            operatorPhone: "", operatorEmail: "", organization: "",
            city: "Aurora", state: "CO", county: "Arapahoe")
    }

    private var template: WinlinkFormTemplate? { WinlinkFormTemplates.template(id: "axterm-park-test") }

    func testItIsFiledApartFromTheOfficialForms() throws {
        let form = try XCTUnwrap(template)
        XCTAssertEqual(form.category, "AXTerm")
        XCTAssertNil(form.xmlAttachmentName, "no Winlink viewer: it is not an official form")
    }

    func testEveryStepIsAPassFailPickList() throws {
        let form = try XCTUnwrap(template)
        for step in steps {
            let field = try XCTUnwrap(form.fields.first { $0.id == step }, step)
            guard case .choice(let options) = field.kind else { return XCTFail("\(step) is not a pick list") }
            XCTAssertEqual(options, ["PASS", "FAIL", "PARTIAL", "SKIP"], step)
            XCTAssertFalse(field.help.isEmpty, "\(step) says what to expect")
        }
    }

    /// The setup is the operator's to type: which radio, TNC and antenna,
    /// where it points, the power and the frequency. Examples show as
    /// placeholders; nothing is filled in for them (operator, 2026-10-08).
    func testTheSetupIsTypedNotPicked() throws {
        let form = try XCTUnwrap(template)
        let values = WinlinkFormEngine.autoFilledValues(for: form, context: context)
        for id in ["Radio", "TNC", "Antenna", "Heading", "Power", "Frequency"] {
            let field = try XCTUnwrap(form.fields.first { $0.id == id }, id)
            guard case .text = field.kind else { return XCTFail("\(id) is not typed") }
            XCTAssertFalse(field.placeholder.isEmpty, "\(id) shows an example")
            XCTAssertEqual(values[id] ?? "", "", "\(id) starts empty")
        }
        XCTAssertFalse(form.fields.contains { $0.id == "S1" || $0.id == "S2" })
    }

    func testTheSetupReadsBackAsTyped() throws {
        let form = try XCTUnwrap(template)
        var values = WinlinkFormEngine.autoFilledValues(for: form, context: context)
        values["Radio"] = "ID-50"
        values["Antenna"] = "Arrow yagi"
        values["Heading"] = "125 true"
        let body = WinlinkFormEngine.render(template: form, values: values, context: context).body
        XCTAssertTrue(body.contains("Radio: ID-50"), body)
        XCTAssertTrue(body.contains("Antenna: Arrow yagi, pointed 125 true"), body)
    }

    func testItGoesToA() throws {
        let values = WinlinkFormEngine.autoFilledValues(for: try XCTUnwrap(template), context: context)
        XCTAssertEqual(values["MsgTo"], "K0EPI-5")
        XCTAssertEqual(values["Newsubject"], "AXTerm park test: K0EPI")
        XCTAssertEqual(values["Grid"], "DM79po")
    }

    func testTheResultsReadAsAPlainReport() throws {
        let form = try XCTUnwrap(template)
        var values = WinlinkFormEngine.autoFilledValues(for: form, context: context)
        values["P1"] = "PASS"
        values["P3"] = "FAIL"
        values["PhoneNotes"] = "P3 took two tries"
        let rendered = WinlinkFormEngine.render(template: form, values: values, context: context)

        XCTAssertEqual(rendered.to, "K0EPI-5")
        XCTAssertTrue(rendered.attachments.isEmpty)
        let lines = rendered.body.components(separatedBy: "\r\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix("  P1 ") && $0.hasSuffix(": PASS") }, rendered.body)
        XCTAssertTrue(lines.contains { $0.hasPrefix("  P3 ") && $0.hasSuffix(": FAIL") }, rendered.body)
        XCTAssertTrue(rendered.body.contains("P3 took two tries"), rendered.body)
        XCTAssertTrue(rendered.body.contains("DM79po"), rendered.body)
    }

    // MARK: - POTA / SOTA activation report

    private var activation: WinlinkFormTemplate? { WinlinkFormTemplates.template(id: "axterm-activation-report") }

    func testTheActivationReportIsAXTermsOwnToo() throws {
        let form = try XCTUnwrap(activation)
        XCTAssertEqual(form.category, "AXTerm")
        XCTAssertNil(form.xmlAttachmentName)
    }

    func testTheActivationReportAsksWhatAnActivatorKnows() throws {
        let form = try XCTUnwrap(activation)
        let program = try XCTUnwrap(form.fields.first { $0.id == "Program" })
        guard case .choice(let options) = program.kind else { return XCTFail("Program is not a pick list") }
        XCTAssertEqual(options, ["POTA", "SOTA", "POTA + SOTA"])
        XCTAssertTrue(try XCTUnwrap(form.fields.first { $0.id == "Reference" }).required)
        XCTAssertTrue(try XCTUnwrap(form.fields.first { $0.id == "MsgTo" }).required)
        let valid = try XCTUnwrap(form.fields.first { $0.id == "Valid" })
        guard case .yesNoUnknown = valid.kind else { return XCTFail("Valid is not yes/no/unknown") }
    }

    func testTheActivationReportReadsAsAPlainReport() throws {
        let form = try XCTUnwrap(activation)
        var values = WinlinkFormEngine.autoFilledValues(for: form, context: context)
        XCTAssertEqual(values["Program"], "POTA")
        XCTAssertEqual(values["Newsubject"], "Activation report: K0EPI")
        values["MsgTo"] = "K0EPI-5"
        values["Reference"] = "US-1234"
        values["RefName"] = "Cherry Creek State Park"
        values["QSOs"] = "14"
        values["Valid"] = "YES"
        let rendered = WinlinkFormEngine.render(template: form, values: values, context: context)

        XCTAssertEqual(rendered.to, "K0EPI-5")
        XCTAssertTrue(rendered.attachments.isEmpty)
        XCTAssertTrue(rendered.body.contains("POTA activation report"), rendered.body)
        XCTAssertTrue(rendered.body.contains("Reference: US-1234  Cherry Creek State Park"), rendered.body)
        XCTAssertTrue(rendered.body.contains("QSOs: 14"), rendered.body)
        XCTAssertTrue(rendered.body.contains("Valid activation: YES"), rendered.body)
    }
}
