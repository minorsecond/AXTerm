import Foundation

/// AXTerm's own forms, filed apart from the official Standard Templates:
/// plain text with no Winlink viewer behind them, filled in the same editor
/// as the ICS forms and sent by Winlink the same way (operator, 2026-10-08).
nonisolated extension WinlinkFormTemplates {

    static let axtermCategory = "AXTerm"

    private static let results = ["PASS", "FAIL", "PARTIAL", "SKIP"]

    private static func position(_ context: WinlinkFormContext) -> String {
        context.location.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? ""
    }

    private static func step(_ id: String, _ label: String, expect: String, section: String) -> WinlinkFormField {
        WinlinkFormField(id: id, label: "\(id) \(label)", kind: .choice(results), help: expect, section: section)
    }

    // MARK: - Park field test

    static let parkTest = WinlinkFormTemplate(
        id: "axterm-park-test",
        title: "AXTerm Park Test",
        category: axtermCategory,
        icon: "checklist",
        summary: "The park field test (Docs/ParkTestPlan.md): a result and notes for each step.",
        templateText: """
        Form:AXTerm Park Test
        To:<var MsgTo>
        Subject: <var Newsubject>
        Msg:
        AXTerm park field test
        Sent: <var DateTime> by <var MsgSender>
        Position: <var Position>  Grid: <var Grid>

        SETUP
          S1 Arrow aimed, TNC4 on the ID-50: <var S1>
          S2 TNC4 connected: <var S2>
        Notes: <var SetupNotes>

        IPHONE
          P1 Chat with K0EPI-2: <var P1>
          P2 Mailbox listing (W PARK): <var P2>
          P3 Download by tapping the name: <var P3>
          P4 Message to the sysop: <var P4>
          P5 Text file to K0EPI-2: <var P5>
          P6 Spreadsheet to K0EPI-2: <var P6>
          P7 Photo at Small to K0EPI-2: <var P7>
          P8 Winlink to K0EPI-5 with attachment: <var P8>
          P9 Upload to the mailbox: <var P9>
        Notes: <var PhoneNotes>

        TUNE
          M1 Tune written, .mid saved: <var M1>
          M2 .mid sent to K0EPI-2: <var M2>
        Notes: <var TuneNotes>

        IPAD
          I1 TNC4 moved to the iPad: <var I1>
          I2 Chat and listing from the iPad: <var I2>
          I3 Photo from the iPad: <var I3>
          R1 This report sent: <var R1>
        Notes: <var IPadNotes>

        OVERALL
        <var Notes>
        """,
        displayFormFile: "",
        fields: [
            WinlinkFormField(id: "MsgTo", label: "To", autoFill: .fixed("K0EPI-5"),
                             help: "A (705)'s Winlink address at home.", required: true, section: "Header"),
            WinlinkFormField(id: "Newsubject", label: "Subject",
                             autoFill: .custom { "AXTerm park test: \($0.callsign)" },
                             required: true, section: "Header"),
            WinlinkFormField(id: "DateTime", label: "Sent",
                             autoFill: .custom { WinlinkFormEngine.formatDateTimeUTC($0.now) }, hidden: true),
            WinlinkFormField(id: "MsgSender", label: "From", autoFill: .callsign, hidden: true),
            WinlinkFormField(id: "Position", label: "Position", autoFill: .custom(position), section: "Where"),
            WinlinkFormField(id: "Grid", label: "Grid square", autoFill: .gridSquare, section: "Where"),

            step("S1", "Arrow aimed, TNC4 on the ID-50", expect: "125° true, elements vertical", section: "Setup"),
            step("S2", "TNC4 connected", expect: "Connected; its settings read", section: "Setup"),
            WinlinkFormField(id: "SetupNotes", label: "Setup notes", kind: .multiline, section: "Setup"),

            step("P1", "Chat with K0EPI-2", expect: "Waiting to send, Sending, Delivered", section: "iPhone"),
            step("P2", "Mailbox listing (W PARK)", expect: "The listing arrives and the history follows it", section: "iPhone"),
            step("P3", "Download by tapping the name", expect: "D fills in; the file arrives; the banner shows", section: "iPhone"),
            step("P4", "Message to the sysop", expect: "Message N stored; 73 de K0EPI-4 on B", section: "iPhone"),
            step("P5", "Text file to K0EPI-2", expect: "AXDP, Completed", section: "iPhone"),
            step("P6", "Spreadsheet to K0EPI-2", expect: "Completed", section: "iPhone"),
            step("P7", "Photo at Small to K0EPI-2", expect: "3 to 5 minutes, no location", section: "iPhone"),
            step("P8", "Winlink to K0EPI-5 with attachment", expect: "Exchange complete: sent 1. No mailbox call open first",
                 section: "iPhone"),
            step("P9", "Upload to the mailbox", expect: "Optional: U, then send at Ready", section: "iPhone"),
            WinlinkFormField(id: "PhoneNotes", label: "iPhone notes", kind: .multiline, section: "iPhone"),

            step("M1", "Tune written, .mid saved", expect: "A few KB in Files", section: "Tune"),
            step("M2", ".mid sent to K0EPI-2", expect: "Under a minute", section: "Tune"),
            WinlinkFormField(id: "TuneNotes", label: "Tune notes", kind: .multiline, section: "Tune"),

            step("I1", "TNC4 moved to the iPad", expect: "The iPhone disconnects the TNC4 first", section: "iPad"),
            step("I2", "Chat and listing from the iPad", expect: "As P1 and P2; banner at the bottom", section: "iPad"),
            step("I3", "Photo from the iPad", expect: "As P7 or P8", section: "iPad"),
            step("R1", "This report sent", expect: "A has it", section: "iPad"),
            WinlinkFormField(id: "IPadNotes", label: "iPad notes", kind: .multiline, section: "iPad"),

            WinlinkFormField(id: "Notes", label: "Overall", kind: .multiline, section: "Overall"),
        ])

    // MARK: - POTA / SOTA activation report

    static let activationReport = WinlinkFormTemplate(
        id: "axterm-activation-report",
        title: "POTA / SOTA Activation",
        category: axtermCategory,
        icon: "mountain.2",
        summary: "Where you activated, when, and how it went: contacts, bands, whether it counts.",
        templateText: """
        Form:AXTerm Activation Report
        To:<var MsgTo>
        Subject: <var Newsubject>
        Msg:
        <var Program> activation report
        Activator: <var MsgSender>   Sent: <var DateTime>
        Reference: <var Reference>  <var RefName>
        Grid: <var Grid>   Position: <var Position>

        Started (UTC): <var Start>
        Ended (UTC): <var End>
        QSOs: <var QSOs>
        Valid activation: <var Valid>
        Bands and modes: <var BandsModes>
        Power and antenna: <var Rig>
        Spotted: <var Spotted>
        Conditions: <var Conditions>

        Notes:
        <var Notes>
        """,
        displayFormFile: "",
        fields: [
            WinlinkFormField(id: "MsgTo", label: "To", placeholder: "Callsign",
                             help: "Who gets the report: a friend, a net, or your own home station for the log.",
                             required: true, section: "Header"),
            WinlinkFormField(id: "Newsubject", label: "Subject",
                             autoFill: .custom { "Activation report: \($0.callsign)" },
                             required: true, section: "Header"),
            WinlinkFormField(id: "DateTime", label: "Sent",
                             autoFill: .custom { WinlinkFormEngine.formatDateTimeUTC($0.now) }, hidden: true),
            WinlinkFormField(id: "MsgSender", label: "Activator", autoFill: .callsign, hidden: true),

            WinlinkFormField(id: "Program", label: "Program", kind: .choice(["POTA", "SOTA", "POTA + SOTA"]),
                             autoFill: .fixed("POTA"), section: "Where"),
            WinlinkFormField(id: "Reference", label: "Reference", placeholder: "US-1234 or W0C/FR-001",
                             required: true, section: "Where"),
            WinlinkFormField(id: "RefName", label: "Park or summit", section: "Where"),
            WinlinkFormField(id: "Grid", label: "Grid square", autoFill: .gridSquare, section: "Where"),
            WinlinkFormField(id: "Position", label: "Position", autoFill: .custom(position), section: "Where"),

            WinlinkFormField(id: "Start", label: "Started (UTC)",
                             autoFill: .custom { WinlinkFormEngine.formatDateTimeUTC($0.now) }, section: "Activation"),
            WinlinkFormField(id: "End", label: "Ended (UTC)", section: "Activation"),
            WinlinkFormField(id: "QSOs", label: "QSOs", placeholder: "Number of contacts", section: "Activation"),
            WinlinkFormField(id: "Valid", label: "Valid activation", kind: .yesNoUnknown,
                             help: "POTA counts an activation at 10 contacts; SOTA scores at 4.",
                             section: "Activation"),
            WinlinkFormField(id: "BandsModes", label: "Bands and modes", placeholder: "20m SSB, 40m CW, 2m FM",
                             section: "Activation"),
            WinlinkFormField(id: "Rig", label: "Power and antenna", section: "Activation"),
            WinlinkFormField(id: "Spotted", label: "Spotted",
                             kind: .choice(["Self-spotted", "Spotted by others", "Not spotted"]), section: "Activation"),
            WinlinkFormField(id: "Conditions", label: "Conditions", placeholder: "Weather, band conditions",
                             section: "Activation"),

            WinlinkFormField(id: "Notes", label: "Notes", kind: .multiline, section: "Notes"),
        ])
}
