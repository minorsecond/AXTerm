import XCTest
@testable import AXTerm

final class WinlinkFormEngineTests: XCTestCase {

    private var context: WinlinkFormContext {
        WinlinkFormContext(
            callsign: "K0EPI",
            appVersion: "1.0",
            now: WinlinkB2Message.dateFormatter.date(from: "2026/08/23 14:30")!,
            location: StationLocation(
                latitude: 39.7392, longitude: -104.9903, gridSquare: "DM79mr",
                source: .gps, timestamp: Date(timeIntervalSince1970: 0)),
            operatorName: "Ross Wardrup",
            operatorNameWithTitle: "Ross Wardrup, EC",
            operatorPhone: "555-0100",
            operatorEmail: "ross@example.com",
            organization: "ARES District 3",
            city: "Denver",
            state: "CO",
            county: "Denver")
    }

    // MARK: - Substitution

    func testSubstituteVarsAndTags() {
        let line = "From: <MsgSender> at <var Place> on <UDTG> keep <unknowntag>"
        let result = WinlinkFormEngine.substitute(
            line,
            values: ["place": "Denver"],
            tags: WinlinkFormEngine.insertionTags(context: context))
        XCTAssertEqual(result, "From: K0EPI at Denver on 231430Z AUG 2026 keep <unknowntag>")
    }

    func testSubstituteMissingVarIsEmpty() {
        XCTAssertEqual(
            WinlinkFormEngine.substitute("[<var Nope>]", values: [:], tags: [:]),
            "[]")
    }

    // MARK: - Check-in rendering

    func testCheckInRendersBodySubjectAndXML() throws {
        let template = WinlinkFormTemplates.checkIn
        var values = WinlinkFormEngine.autoFilledValues(for: template, context: context)
        XCTAssertEqual(values["Newsubject"], "Winlink Check-in: K0EPI")
        XCTAssertEqual(values["ContactName"], "Ross Wardrup")
        XCTAssertEqual(values["Grid"], "DM79mr")
        XCTAssertEqual(values["mapLat"], "39.7392")
        XCTAssertEqual(values["Status"], "NET")

        values["MsgTo"] = "K0NTS-10"
        values["Comments"] = "All quiet."
        let rendered = WinlinkFormEngine.render(template: template, values: values, context: context)

        XCTAssertEqual(rendered.to, "K0NTS-10")
        XCTAssertEqual(rendered.subject, "Winlink Check-in: K0EPI")
        XCTAssertTrue(rendered.body.contains("Winlink Check-in"), rendered.body)
        XCTAssertTrue(rendered.body.contains("1c. From:\tK0EPI"), rendered.body)
        XCTAssertTrue(rendered.body.contains("3e. Grid Square:\tDM79mr"), rendered.body)
        XCTAssertTrue(rendered.body.contains("All quiet."), rendered.body)

        XCTAssertEqual(rendered.attachments.count, 1)
        XCTAssertEqual(rendered.attachments[0].name, "RMS_Express_Form_Winlink_Check_In_Viewer.xml")

        let form = try XCTUnwrap(WinlinkReceivedForm.parse(rendered.attachments[0].data))
        XCTAssertEqual(form.displayForm, "Winlink_Check_In_Viewer.html")
        XCTAssertEqual(form.sendersCallsign, "K0EPI")
        XCTAssertEqual(form.gridSquare, "DM79MR")
        XCTAssertEqual(form.submissionDatetime, "20260823143000")
        XCTAssertEqual(form.variables.first(where: { $0.name == "msgto" })?.value, "K0NTS-10")
        XCTAssertEqual(form.variables.first(where: { $0.name == "comments" })?.value, "All quiet.")
        // Variables are sorted for deterministic output.
        XCTAssertEqual(form.variables.map(\.name), form.variables.map(\.name).sorted())
    }

    // MARK: - ICS-213

    func testICS213SubjectConvention() {
        let template = WinlinkFormTemplates.ics213
        var values = WinlinkFormEngine.autoFilledValues(for: template, context: context)
        values["Subjectline"] = "Shelter status"
        values["To_Name"] = "EOC Duty Officer"
        values["Message"] = "Shelter at capacity."

        let rendered = WinlinkFormEngine.render(template: template, values: values, context: context)
        XCTAssertEqual(rendered.subject, "ICS-213: Shelter status - 2026-08-23 08:30:00")
        XCTAssertTrue(rendered.body.contains("GENERAL MESSAGE (ICS 213)"), rendered.body)
        XCTAssertTrue(rendered.body.contains("3. From (Name and Position): Ross Wardrup, EC"), rendered.body)
        XCTAssertTrue(rendered.body.contains("Shelter at capacity."), rendered.body)
        XCTAssertTrue(rendered.body.contains("Express Sending Station: K0EPI"), rendered.body)
        XCTAssertEqual(rendered.attachments[0].name, "RMS_Express_Form_ICS213_Initial_Viewer.xml")
    }

    // MARK: - FSR

    func testFSRSubjectCarriesPrecedenceAndDTG() {
        let template = WinlinkFormTemplates.fieldSituationReport
        var values = WinlinkFormEngine.autoFilledValues(for: template, context: context)
        values["MsgTo"] = "SEC@winlink.org"
        values["Precedence"] = "PRIORITY"
        values["k9"] = "NO"
        values["Comm6"] = "Grid down since 0600"

        let rendered = WinlinkFormEngine.render(template: template, values: values, context: context)
        XCTAssertEqual(rendered.subject, "//WL2K PRIORITY/ Field Situation Report 231430Z AUG 2026")
        XCTAssertTrue(rendered.body.contains("9a. Commercial Power functioning: [ NO ]  Grid down since 0600"), rendered.body)
        XCTAssertTrue(rendered.body.contains("2. City:Denver  County:Denver State: CO"), rendered.body)
    }

    // MARK: - Position report

    func testPositionReportIsPlainTextToQTH() {
        let template = WinlinkFormTemplates.gpsPositionReport
        var values = WinlinkFormEngine.autoFilledValues(for: template, context: context)
        XCTAssertEqual(values["Lat"], "39.7392N")
        XCTAssertEqual(values["Lon"], "104.9903W")
        values["Message"] = "Portable at the fairgrounds"

        let rendered = WinlinkFormEngine.render(template: template, values: values, context: context)
        XCTAssertEqual(rendered.to, "QTH")
        XCTAssertEqual(rendered.subject, "Position Report")
        XCTAssertTrue(rendered.attachments.isEmpty, "position reports carry no form XML")
        XCTAssertTrue(rendered.body.contains("Latitude: 39.7392N"), rendered.body)
        XCTAssertTrue(rendered.body.contains("Comment: Portable at the fairgrounds"), rendered.body)
    }

    // MARK: - XML details

    func testXMLEscaping() {
        XCTAssertEqual(WinlinkFormEngine.escapeXML(#"a<b&c>"d""#), "a&lt;b&amp;c&gt;&quot;d&quot;")
    }

    func testIsFormAttachment() {
        XCTAssertTrue(WinlinkReceivedForm.isFormAttachment("RMS_Express_Form_ICS213_Initial_Viewer.xml"))
        XCTAssertTrue(WinlinkReceivedForm.isFormAttachment("RMS_Express_Form_Field Situation Report viewer.xml"))
        XCTAssertFalse(WinlinkReceivedForm.isFormAttachment("photo.jpg"))
        XCTAssertFalse(WinlinkReceivedForm.isFormAttachment("form.xml"))
    }

    func testParseRejectsNonFormXML() {
        XCTAssertNil(WinlinkReceivedForm.parse(Data("<other><a>1</a></other>".utf8)))
        XCTAssertNil(WinlinkReceivedForm.parse(Data("not xml at all".utf8)))
    }

    func testAllTemplatesRenderWithoutValues() {
        // Smoke: every catalog template renders from bare auto-fills.
        for template in WinlinkFormTemplates.all {
            let values = WinlinkFormEngine.autoFilledValues(for: template, context: context)
            let rendered = WinlinkFormEngine.render(template: template, values: values, context: context)
            XCTAssertFalse(rendered.body.isEmpty, template.id)
            XCTAssertFalse(rendered.body.contains("<var "), "unsubstituted var in \(template.id): \(rendered.body)")
        }
    }
}
