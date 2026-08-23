import Foundation

/// The curated form catalog: high-value Standard Templates rendered as
/// native SwiftUI forms. Interop contract: bodies come from the official
/// template text; the XML attachment targets each form's official viewer
/// so Winlink Express (and every other client) renders them natively.
nonisolated enum WinlinkFormTemplates {

    static let all: [WinlinkFormTemplate] = [
        checkIn, checkOut, ics213, fieldSituationReport, severeWeather, gpsPositionReport,
    ]

    static func template(id: String) -> WinlinkFormTemplate? {
        all.first { $0.id == id }
    }

    private static let templateVersionNote = "AXTerm Forms (Standard Templates 1.1.20.0)"

    // MARK: - Winlink Check-in / Check-out

    private static func checkFields(kind: String) -> [WinlinkFormField] {
        [
            WinlinkFormField(id: "MsgTo", label: "To", autoFill: nil,
                             placeholder: "Net control / tactical address",
                             help: "Where the \(kind) goes — a net control callsign or tactical address.",
                             required: true, section: "Header"),
            WinlinkFormField(id: "Newsubject", label: "Subject",
                             autoFill: .custom { "Winlink \(kind): \($0.callsign)" },
                             required: true, section: "Header"),
            WinlinkFormField(id: "Organization", label: "Organization / net",
                             autoFill: .organization, section: "Header"),
            WinlinkFormField(id: "exercise_id", label: "Event / exercise ID", section: "Header"),

            WinlinkFormField(id: "DateTime", label: "Date/Time", autoFill: .dateTimeLocal,
                             hidden: true, section: "Station"),
            WinlinkFormField(id: "MsgSender", label: "From", autoFill: .callsign,
                             hidden: true, section: "Station"),
            WinlinkFormField(id: "ContactName", label: "Station contact name",
                             autoFill: .operatorName, section: "Station"),
            WinlinkFormField(id: "Assigned", label: "Operators on station",
                             autoFill: .operatorName, section: "Station"),

            WinlinkFormField(id: "Status", label: "Type",
                             kind: .choice(["EXERCISE", "REAL EVENT", "NET"]),
                             autoFill: .fixed("NET"), section: "Session"),
            WinlinkFormField(id: "Service", label: "Service",
                             kind: .choice(["AMATEUR", "SHARES"]),
                             autoFill: .fixed("AMATEUR"), section: "Session"),
            WinlinkFormField(id: "Band", label: "Band",
                             kind: .choice(["VHF", "UHF", "HF", "SHF", "NA"]),
                             autoFill: .fixed("VHF"), section: "Session"),
            WinlinkFormField(id: "Session", label: "Session / mode",
                             kind: .choice(["Packet", "Telnet", "VARA FM", "VARA HF", "Ardop", "Pactor", "Robust Packet", "Mesh"]),
                             autoFill: .fixed("Packet"), section: "Session"),

            WinlinkFormField(id: "Location", label: "Location description",
                             autoFill: .custom { context in
                                 [context.city, context.state].filter { !$0.isEmpty }.joined(separator: ", ")
                             },
                             section: "Location"),
            WinlinkFormField(id: "mapLat", label: "Latitude", autoFill: .latitude, hidden: true),
            WinlinkFormField(id: "mapLon", label: "Longitude", autoFill: .longitude, hidden: true),
            WinlinkFormField(id: "MGRS", label: "MGRS", hidden: true),
            WinlinkFormField(id: "Grid", label: "Grid square", autoFill: .gridSquare, section: "Location"),
            WinlinkFormField(id: "locationSource", label: "Location source",
                             autoFill: .locationSource, hidden: true),

            WinlinkFormField(id: "Comments", label: "Comments", kind: .multiline, section: "Comments"),

            WinlinkFormField(id: "Templateversion", label: "", autoFill: .fixed(templateVersionNote), hidden: true),
            WinlinkFormField(id: "Mapfilename", label: "", hidden: true),
        ]
    }

    static let checkIn = WinlinkFormTemplate(
        id: "winlink-check-in",
        title: "Winlink Check-in",
        category: "General",
        icon: "person.crop.circle.badge.checkmark",
        summary: "Standard net/event check-in: station, session, and position.",
        templateText: WinlinkFormTemplateTexts.checkin,
        displayFormFile: "Winlink_Check_In_Viewer.html",
        fields: checkFields(kind: "Check-in"))

    static let checkOut = WinlinkFormTemplate(
        id: "winlink-check-out",
        title: "Winlink Check-out",
        category: "General",
        icon: "person.crop.circle.badge.xmark",
        summary: "Closing check-out at the end of a net, shift, or event.",
        templateText: WinlinkFormTemplateTexts.checkout,
        displayFormFile: "Winlink_Check_out_Viewer.html",
        fields: checkFields(kind: "Check-out"))

    // MARK: - ICS-213 General Message

    static let ics213 = WinlinkFormTemplate(
        id: "ics-213",
        title: "ICS-213 General Message",
        category: "ICS / FEMA",
        icon: "doc.text",
        summary: "The FEMA/ICS general message form used across EmComm.",
        templateText: WinlinkFormTemplateTexts.ics213,
        displayFormFile: "ICS213_Initial_Viewer.html",
        replyTemplateFile: "ICS213_SendReply.0",
        fields: [
            WinlinkFormField(id: "IsExercise", label: "Exercise message",
                             kind: .choice(["** THIS IS AN EXERCISE MESSAGE **", ""]),
                             autoFill: .fixed("** THIS IS AN EXERCISE MESSAGE **"),
                             help: "ICS practice: every drill message is clearly marked as an exercise.",
                             section: "Header"),
            WinlinkFormField(id: "inc_name", label: "1. Incident name", section: "Header"),
            WinlinkFormField(id: "To_Name", label: "2. To (name and position)",
                             required: true, section: "Header"),
            WinlinkFormField(id: "fm_name", label: "3. From (name and position)",
                             autoFill: .operatorNameWithTitle, required: true, section: "Header"),
            WinlinkFormField(id: "Subjectline", label: "4. Subject", required: true, section: "Header"),
            WinlinkFormField(id: "Mdate", label: "5. Date",
                             autoFill: .custom { WinlinkFormEngine.formatDate($0.now, utc: false) },
                             section: "Header"),
            WinlinkFormField(id: "mtime", label: "6. Time",
                             autoFill: .custom { WinlinkFormEngine.formatTime($0.now, utc: false) },
                             section: "Header"),

            WinlinkFormField(id: "Message", label: "7. Message", kind: .multiline,
                             required: true, section: "Message"),

            WinlinkFormField(id: "Approved_Name", label: "8. Approved by",
                             autoFill: .operatorName, section: "Approval"),
            WinlinkFormField(id: "Approved_PosTitle", label: "8a. Position/title", section: "Approval"),

            WinlinkFormField(id: "FormTitle", label: "", autoFill: .fixed(""), hidden: true),
            WinlinkFormField(id: "txtStr", label: "", hidden: true),
            WinlinkFormField(id: "theMsgSender", label: "", autoFill: .callsign, hidden: true),
            WinlinkFormField(id: "mapLat", label: "", autoFill: .latitude, hidden: true),
            WinlinkFormField(id: "mapLon", label: "", autoFill: .longitude, hidden: true),
            WinlinkFormField(id: "MGRS", label: "", hidden: true),
            WinlinkFormField(id: "locationSource", label: "", autoFill: .locationSource, hidden: true),
            WinlinkFormField(id: "Templateversion", label: "", autoFill: .fixed(templateVersionNote), hidden: true),
        ])

    // MARK: - Field Situation Report

    private static func utilityField(_ id: String, _ label: String) -> WinlinkFormField {
        WinlinkFormField(id: id, label: label, kind: .yesNoUnknown,
                         autoFill: .fixed("UNK"), section: "Infrastructure")
    }

    static let fieldSituationReport = WinlinkFormTemplate(
        id: "field-situation-report",
        title: "Field Situation Report",
        category: "Disaster / EmComm",
        icon: "waveform.path.ecg",
        summary: "The ARES/EmComm ground-truth report: utilities, comms, and life-safety needs at your location.",
        templateText: WinlinkFormTemplateTexts.fsr,
        displayFormFile: "Field Situation Report viewer.html",
        fields: [
            WinlinkFormField(id: "MsgTo", label: "To", required: true, section: "Header"),
            WinlinkFormField(id: "MsgCc", label: "Cc", section: "Header"),
            WinlinkFormField(id: "Precedence", label: "Precedence",
                             kind: .choice(["ROUTINE", "PRIORITY", "IMMEDIATE", "FLASH"]),
                             autoFill: .fixed("ROUTINE"),
                             help: "Message handling precedence. Anything above ROUTINE implies urgency to every relay station.",
                             section: "Header"),
            WinlinkFormField(id: "UDTGfld", label: "Date-time group", autoFill: .utcDTG,
                             hidden: true, section: "Header"),
            WinlinkFormField(id: "MsgNR", label: "Task number", section: "Header"),
            WinlinkFormField(id: "Title", label: "Agency / group", autoFill: .organization, section: "Header"),

            WinlinkFormField(id: "Safetyneed", label: "Emergent / life-safety need",
                             kind: .choice(["NO", "YES"]), autoFill: .fixed("NO"),
                             help: "YES flags this report as carrying an immediate life-safety need — say what is needed below.",
                             required: true, section: "Life safety"),
            WinlinkFormField(id: "Comm0", label: "Life-safety needs", kind: .multiline, section: "Life safety"),

            WinlinkFormField(id: "City", label: "City", autoFill: .city, section: "Location"),
            WinlinkFormField(id: "County", label: "County", autoFill: .county, section: "Location"),
            WinlinkFormField(id: "State", label: "State", autoFill: .state, section: "Location"),
            WinlinkFormField(id: "Territory", label: "Territory", section: "Location"),
            WinlinkFormField(id: "gpsLat", label: "", autoFill: .latitude, hidden: true),
            WinlinkFormField(id: "gpsLon", label: "", autoFill: .longitude, hidden: true),
            WinlinkFormField(id: "MGRS", label: "", hidden: true),
            WinlinkFormField(id: "locationSource", label: "", autoFill: .locationSource, hidden: true),

            utilityField("k4", "POTS landlines"),
            utilityField("k4A", "VOIP landlines"),
            utilityField("k5", "Cell voice"),
            utilityField("k5A", "Cell texts"),
            utilityField("AMFM", "AM/FM broadcast"),
            utilityField("TVStatus", "OTA TV"),
            utilityField("TVStatusb", "Satellite TV"),
            utilityField("TVStatusc", "Cable TV"),
            utilityField("WaterWorks", "Public water"),
            utilityField("k9", "Commercial power"),
            utilityField("k9A", "Power stable"),
            utilityField("kgc9", "Natural gas"),
            utilityField("Inter", "Internet"),
            utilityField("NOAA", "NOAA weather radio"),
            utilityField("NOAAb", "NOAA audio degraded"),

            // Per-utility comment lines (shown as one notes field each in
            // the template; left blank unless filled).
            WinlinkFormField(id: "Comm1", label: "POTS notes", hidden: true),
            WinlinkFormField(id: "Comm1A", label: "VOIP notes", hidden: true),
            WinlinkFormField(id: "Comm2", label: "Cell voice notes", hidden: true),
            WinlinkFormField(id: "Comm2A", label: "Cell text notes", hidden: true),
            WinlinkFormField(id: "Comm3", label: "AM/FM notes", hidden: true),
            WinlinkFormField(id: "Comm4", label: "OTA TV notes", hidden: true),
            WinlinkFormField(id: "Comm4b", label: "Sat TV notes", hidden: true),
            WinlinkFormField(id: "Comm4c", label: "Cable TV notes", hidden: true),
            WinlinkFormField(id: "Comm5", label: "Water notes", hidden: true),
            WinlinkFormField(id: "Comm6", label: "Power notes", hidden: true),
            WinlinkFormField(id: "Comm6A", label: "Power stability notes", hidden: true),
            WinlinkFormField(id: "Comm9c", label: "Gas notes", hidden: true),
            WinlinkFormField(id: "Comm7", label: "Internet notes", hidden: true),
            WinlinkFormField(id: "NOAAcom", label: "NOAA notes", hidden: true),
            WinlinkFormField(id: "NOAAcomb", label: "NOAA audio notes", hidden: true),

            WinlinkFormField(id: "Message", label: "Additional comments", kind: .multiline, section: "Comments"),
            WinlinkFormField(id: "POC", label: "Point of contact",
                             autoFill: .custom { context in
                                 [context.operatorName, context.operatorPhone]
                                     .filter { !$0.isEmpty }.joined(separator: " ")
                             },
                             section: "Comments"),

            WinlinkFormField(id: "MsgSender", label: "", autoFill: .callsign, hidden: true),
            WinlinkFormField(id: "Templateversion", label: "", autoFill: .fixed(templateVersionNote), hidden: true),
            WinlinkFormField(id: "mapfilename", label: "", hidden: true),
        ])

    // MARK: - Severe Weather Report

    static let severeWeather = WinlinkFormTemplate(
        id: "severe-wx-report",
        title: "Severe Weather Report",
        category: "Weather",
        icon: "cloud.bolt.rain",
        summary: "SKYWARN-style severe weather observation report.",
        templateText: WinlinkFormTemplateTexts.severewx,
        displayFormFile: "Severe WX Report viewer.html",
        fields: [
            WinlinkFormField(id: "Type", label: "Report status",
                             kind: .choice(["EXERCISE", "REAL EVENT"]),
                             autoFill: .fixed("REAL EVENT"), section: "Header"),
            WinlinkFormField(id: "Call", label: "", autoFill: .callsign, hidden: true),
            WinlinkFormField(id: "RepName", label: "Reporting party",
                             autoFill: .operatorName, required: true, section: "Header"),
            WinlinkFormField(id: "Phone", label: "Phone", autoFill: .operatorPhone, section: "Header"),
            WinlinkFormField(id: "Email", label: "Email", autoFill: .operatorEmail, section: "Header"),
            WinlinkFormField(id: "DateTime", label: "", autoFill: .dateTimeLocal, hidden: true),

            WinlinkFormField(id: "Region", label: "State / region", autoFill: .state,
                             required: true, section: "Event area"),
            WinlinkFormField(id: "County", label: "County", autoFill: .county, section: "Event area"),
            WinlinkFormField(id: "City", label: "City", autoFill: .city, section: "Event area"),
            WinlinkFormField(id: "Other", label: "Other location detail", section: "Event area"),
            WinlinkFormField(id: "mapLat", label: "", autoFill: .latitude, hidden: true),
            WinlinkFormField(id: "mapLon", label: "", autoFill: .longitude, hidden: true),
            WinlinkFormField(id: "MGRS", label: "", hidden: true),
            WinlinkFormField(id: "locationSource", label: "", autoFill: .locationSource, hidden: true),

            WinlinkFormField(id: "Flood", label: "Flooding", placeholder: "e.g. street flooding, 2 ft over road", section: "Observed conditions"),
            WinlinkFormField(id: "HailSize", label: "Hail size", placeholder: "e.g. 1 in / quarter", section: "Observed conditions"),
            WinlinkFormField(id: "WindspeedI", label: "Wind speed (mph)", section: "Observed conditions"),
            WinlinkFormField(id: "WindspeedM", label: "Wind speed (km/h)", section: "Observed conditions"),
            WinlinkFormField(id: "Tornado", label: "Tornado / funnel cloud", placeholder: "seen / radar-indicated / none", section: "Observed conditions"),
            WinlinkFormField(id: "WindDamage", label: "Wind damage", section: "Observed conditions"),
            WinlinkFormField(id: "Precipitation", label: "Winter precipitation", section: "Observed conditions"),
            WinlinkFormField(id: "SnowI", label: "Snow (in)", section: "Observed conditions"),
            WinlinkFormField(id: "SnowM", label: "Snow (cm)", section: "Observed conditions"),
            WinlinkFormField(id: "FreezingRainI", label: "Freezing rain (in)", section: "Observed conditions"),
            WinlinkFormField(id: "FreezingRainM", label: "Freezing rain (mm)", section: "Observed conditions"),
            WinlinkFormField(id: "RainI", label: "Heavy rain (in)", section: "Observed conditions"),
            WinlinkFormField(id: "RainM", label: "Heavy rain (mm)", section: "Observed conditions"),
            WinlinkFormField(id: "RainPeriod", label: "Rain period (hours)", section: "Observed conditions"),

            WinlinkFormField(id: "Comments", label: "Comments", kind: .multiline, section: "Comments"),
        ])

    // MARK: - GPS / Position Report

    /// Plain-text report to the QTH system address — this is how a
    /// position lands on the Winlink map. No XML viewer involved.
    static let gpsPositionReport = WinlinkFormTemplate(
        id: "gps-position-report",
        title: "Position Report",
        category: "General",
        icon: "location.circle",
        summary: "Posts your position to the Winlink map (message to QTH).",
        templateText: WinlinkFormTemplateTexts.gps,
        displayFormFile: "",
        fields: [
            WinlinkFormField(id: "thetime", label: "Time",
                             autoFill: .custom { WinlinkFormEngine.formatDateTimeUTC($0.now) },
                             hidden: true),
            WinlinkFormField(id: "Lat", label: "Latitude",
                             autoFill: .custom { $0.location.map { StationLocationFormat.decimal($0).components(separatedBy: " ").first ?? "" } ?? "" },
                             required: true, section: "Position"),
            WinlinkFormField(id: "Lon", label: "Longitude",
                             autoFill: .custom { $0.location.map { StationLocationFormat.decimal($0).components(separatedBy: " ").last ?? "" } ?? "" },
                             required: true, section: "Position"),
            WinlinkFormField(id: "Message", label: "Comment",
                             placeholder: "e.g. Portable at the fairgrounds",
                             section: "Position"),
        ])
}
