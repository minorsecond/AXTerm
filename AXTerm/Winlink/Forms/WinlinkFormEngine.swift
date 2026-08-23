import Foundation

/// Everything the engine needs to resolve insertion tags and auto-fills.
nonisolated struct WinlinkFormContext: Sendable {
    var callsign: String
    var appVersion: String
    var now: Date
    var location: StationLocation?
    var operatorName: String = ""
    var operatorNameWithTitle: String = ""
    var operatorPhone: String = ""
    var operatorEmail: String = ""
    var organization: String = ""
    var city: String = ""
    var state: String = ""
    var county: String = ""
}

/// Output of rendering a form: everything needed to build the message.
nonisolated struct WinlinkRenderedForm: Sendable {
    var to: String
    var cc: String
    var subject: String
    var body: String
    var attachments: [WinlinkB2Message.Attachment]
}

/// Renders Winlink Standard Templates: control lines (`To:`/`Subject:`/
/// `Msg:`), `<var x>` substitution, the official insertion tags, and the
/// Winlink Express-compatible `RMS_Express_Form_*.xml` attachment
/// (schema per the reference implementations — see Docs/Winlink.md).
nonisolated enum WinlinkFormEngine {

    // MARK: - Auto-fill

    /// Default values for a template's fields from the context.
    static func autoFilledValues(for template: WinlinkFormTemplate, context: WinlinkFormContext) -> [String: String] {
        var values = [String: String]()
        for field in template.fields {
            values[field.id] = resolveAutoFill(field.autoFill, context: context) ?? ""
        }
        return values
    }

    private static func resolveAutoFill(_ autoFill: WinlinkFormField.AutoFill?, context: WinlinkFormContext) -> String? {
        guard let autoFill else { return nil }
        switch autoFill {
        case .callsign: return context.callsign
        case .dateTimeLocal: return formatDateTimeLocal(context.now)
        case .utcDTG: return formatUDTG(context.now)
        case .latitude:
            return context.location.map { String(format: "%.4f", $0.latitude) } ?? ""
        case .longitude:
            return context.location.map { String(format: "%.4f", $0.longitude) } ?? ""
        case .gridSquare: return context.location?.gridSquare ?? ""
        case .locationSource: return context.location?.source.rawValue ?? ""
        case .operatorName: return context.operatorName
        case .operatorNameWithTitle: return context.operatorNameWithTitle
        case .operatorPhone: return context.operatorPhone
        case .operatorEmail: return context.operatorEmail
        case .organization: return context.organization
        case .city: return context.city
        case .state: return context.state
        case .county: return context.county
        case .fixed(let value): return value
        case .custom(let make): return make(context)
        }
    }

    // MARK: - Rendering

    static func render(
        template: WinlinkFormTemplate,
        values: [String: String],
        context: WinlinkFormContext
    ) -> WinlinkRenderedForm {
        let lowercasedValues = Dictionary(
            values.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first })
        let tags = insertionTags(context: context)

        var to = ""
        var cc = ""
        var subject = ""
        var bodyLines = [String]()
        var inBody = false

        for rawLine in template.templateText.components(separatedBy: .newlines) {
            let substituted = substitute(rawLine, values: lowercasedValues, tags: tags)

            if inBody {
                bodyLines.append(substituted)
                continue
            }

            // Control lines (before Msg:). Keys are case-insensitive.
            let parts = substituted.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            let value = parts.count > 1 ? String(parts[1]) : ""

            switch key {
            case "msg":
                inBody = true
                let first = value.trimmingCharacters(in: .whitespaces)
                if !first.isEmpty { bodyLines.append(first) }
            case "to":
                to = value.trimmingCharacters(in: .whitespaces)
            case "cc":
                cc = value.trimmingCharacters(in: .whitespaces)
            case "subject", "subj":
                subject = value.trimmingCharacters(in: .whitespaces)
            case "form", "replytemplate", "readonly", "seqinc", "seqset", "def", "define", "sender", "from":
                continue
            default:
                continue
            }
        }

        var attachments = [WinlinkB2Message.Attachment]()
        if let xmlName = template.xmlAttachmentName {
            let xml = buildXML(template: template, values: values, context: context)
            attachments.append(.init(name: xmlName, data: xml))
        }

        return WinlinkRenderedForm(
            to: to,
            cc: cc,
            subject: subject,
            body: bodyLines.joined(separator: "\r\n") + "\r\n",
            attachments: attachments)
    }

    /// Replaces `<var name>` from values and `<Tag>` insertion tags.
    /// Unresolved variables render as empty; unknown bare tags are left
    /// alone (they may be literal text like `<...>` markers).
    static func substitute(_ line: String, values: [String: String], tags: [String: String]) -> String {
        var result = ""
        var remainder = Substring(line)

        while let open = remainder.firstIndex(of: "<") {
            result += remainder[..<open]
            let afterOpen = remainder.index(after: open)
            guard let close = remainder[afterOpen...].firstIndex(of: ">") else {
                result += remainder[open...]
                return result
            }
            let token = String(remainder[afterOpen..<close]).trimmingCharacters(in: .whitespaces)
            let lowered = token.lowercased()

            if lowered.hasPrefix("var ") {
                let name = String(token.dropFirst(4)).trimmingCharacters(in: .whitespaces).lowercased()
                result += values[name] ?? ""
            } else if let tag = tags.first(where: { $0.key.lowercased() == lowered })?.value {
                result += tag
            } else if let value = values[lowered] {
                // Some templates reference variables without the var keyword.
                result += value
            } else {
                result += "<\(token)>"
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        result += remainder
        return result
    }

    // MARK: - Insertion tags (RMSE_FORMS/insertion_tags conventions)

    static func insertionTags(context: WinlinkFormContext) -> [String: String] {
        let location = context.location
        return [
            "MsgSender": context.callsign,
            "Callsign": context.callsign,
            "ProgramVersion": "AXTerm \(context.appVersion)",
            "SeqNum": "0",
            "MsgTo": "",
            "MsgIsReply": "False",
            "MsgIsForward": "False",
            "MsgIsAcknowledgement": "False",

            "DateTime": formatDateTimeLocal(context.now),
            "UDateTime": formatDateTimeUTC(context.now),
            "Date": formatDate(context.now, utc: false),
            "UDate": formatDate(context.now, utc: true),
            "UDTG": formatUDTG(context.now),
            "Time": formatTime(context.now, utc: false),
            "UTime": formatTime(context.now, utc: true),

            "GPS": location.map { StationLocationFormat.degreeMinute($0) } ?? "(Not available)",
            "GPSValid": location?.source == .gps ? "YES" : "NO",
            "GPS_DECIMAL": location.map { StationLocationFormat.decimal($0) } ?? "(Not available)",
            "GPS_SIGNED_DECIMAL": location.map { StationLocationFormat.signedDecimal($0) } ?? "(Not available)",
            "GridSquare": location?.gridSquare ?? "(Not available)",
            "Latitude": location.map { String(format: "%.4f", $0.latitude) } ?? "",
            "Longitude": location.map { String(format: "%.4f", $0.longitude) } ?? "",
            "GPSLatitude": location.map { String(format: "%.4f", $0.latitude) } ?? "",
            "GPSLongitude": location.map { String(format: "%.4f", $0.longitude) } ?? "",

            "InternetAvailable": "NO",
        ]
    }

    // MARK: - XML attachment

    /// `RMS_Express_Form` XML, matching the reference implementations:
    /// form_parameters (version, callsign, grid, display/reply files)
    /// followed by the variables sorted by name, keys lowercased.
    static func buildXML(
        template: WinlinkFormTemplate,
        values: [String: String],
        context: WinlinkFormContext
    ) -> Data {
        let submission = formatSubmissionDatetime(context.now)
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<RMS_Express_Form>\n"
        xml += "    <form_parameters>\n"
        xml += "        <xml_file_version>1.0</xml_file_version>\n"
        xml += "        <rms_express_version>AXTerm \(escapeXML(context.appVersion))</rms_express_version>\n"
        xml += "        <submission_datetime>\(submission)</submission_datetime>\n"
        xml += "        <senders_callsign>\(escapeXML(context.callsign))</senders_callsign>\n"
        xml += "        <grid_square>\(escapeXML(context.location?.gridSquare.uppercased() ?? ""))</grid_square>\n"
        xml += "        <display_form>\(escapeXML(template.displayFormFile))</display_form>\n"
        xml += "        <reply_template>\(escapeXML(template.replyTemplateFile))</reply_template>\n"
        xml += "    </form_parameters>\n"
        xml += "    <variables>\n"
        for (name, value) in values
            .map({ ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) })
            .sorted(by: { $0.0 < $1.0 }) {
            xml += "        <\(name)>\(escapeXML(value))</\(name)>\n"
        }
        xml += "    </variables>\n"
        xml += "</RMS_Express_Form>"
        return Data(xml.utf8)
    }

    static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Date formats (matching the reference implementations)

    private static func formatter(_ format: String, utc: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if utc { formatter.timeZone = TimeZone(identifier: "UTC") }
        return formatter
    }

    static func formatDateTimeLocal(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm:ss", utc: false).string(from: date)
    }

    static func formatDateTimeUTC(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm:ss'Z'", utc: true).string(from: date)
    }

    static func formatDate(_ date: Date, utc: Bool) -> String {
        formatter(utc ? "yyyy-MM-dd'Z'" : "yyyy-MM-dd", utc: utc).string(from: date)
    }

    static func formatTime(_ date: Date, utc: Bool) -> String {
        formatter(utc ? "HH:mm:ss'Z'" : "HH:mm:ss", utc: utc).string(from: date)
    }

    /// `231430Z AUG 2026` — the military date-time group.
    static func formatUDTG(_ date: Date) -> String {
        formatter("ddHHmm'Z' MMM yyyy", utc: true).string(from: date).uppercased()
    }

    static func formatSubmissionDatetime(_ date: Date) -> String {
        formatter("yyyyMMddHHmmss", utc: true).string(from: date)
    }
}

// MARK: - Received-form parsing

/// A parsed `RMS_Express_Form_*.xml` attachment from a received message.
nonisolated struct WinlinkReceivedForm: Equatable, Sendable {
    var displayForm: String
    var sendersCallsign: String
    var gridSquare: String
    var submissionDatetime: String
    /// Variables in document order.
    var variables: [(name: String, value: String)]

    static func == (lhs: WinlinkReceivedForm, rhs: WinlinkReceivedForm) -> Bool {
        lhs.displayForm == rhs.displayForm
            && lhs.sendersCallsign == rhs.sendersCallsign
            && lhs.gridSquare == rhs.gridSquare
            && lhs.submissionDatetime == rhs.submissionDatetime
            && lhs.variables.map(\.name) == rhs.variables.map(\.name)
            && lhs.variables.map(\.value) == rhs.variables.map(\.value)
    }

    /// True when the attachment name marks a Winlink form payload.
    static func isFormAttachment(_ name: String) -> Bool {
        name.hasPrefix("RMS_Express_Form_") && name.lowercased().hasSuffix(".xml")
    }

    static func parse(_ data: Data) -> WinlinkReceivedForm? {
        let parser = FormXMLParser()
        return parser.parse(data)
    }
}

/// Small XMLParser wrapper for the RMS_Express_Form schema.
private nonisolated final class FormXMLParser: NSObject, XMLParserDelegate {

    private var path = [String]()
    private var text = ""
    private var parameters = [String: String]()
    private var variables = [(name: String, value: String)]()
    private var sawRoot = false

    func parse(_ data: Data) -> WinlinkReceivedForm? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), sawRoot else { return nil }
        return WinlinkReceivedForm(
            displayForm: parameters["display_form"] ?? "",
            sendersCallsign: parameters["senders_callsign"] ?? "",
            gridSquare: parameters["grid_square"] ?? "",
            submissionDatetime: parameters["submission_datetime"] ?? "",
            variables: variables)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if elementName == "RMS_Express_Form" { sawRoot = true }
        path.append(elementName)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count == 3, path[1] == "form_parameters" {
            parameters[elementName] = value
        } else if path.count == 3, path[1] == "variables" {
            variables.append((name: elementName, value: value))
        }
        path.removeLast()
        text = ""
    }
}
