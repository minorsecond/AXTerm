import Foundation

/// The short tag a packet list shows for a frame, and the sentence behind it.
///
/// Connected-mode frames keep their control-field classification (DATA, ACK,
/// RETRY, CTRL, ROUTE). A UI frame is refined by what it carries: the APRS
/// data type when it decodes as APRS, otherwise ID, MAIL or BCN, the words
/// the terminal's filter chips use for the same lines. Every APRS frame used
/// to read BEACON, Mic-E positions, objects, telemetry, status reports and
/// messages alike.
///
/// Display only. Routing and link quality read `PacketClassification`, which
/// this does not change.
nonisolated struct PacketTypeTag: Equatable, Sendable {
    let label: String
    let tooltip: String

    static func of(_ packet: Packet) -> PacketTypeTag {
        let classification = packet.classification
        guard classification == .uiBeacon else {
            return PacketTypeTag(label: classification.badge, tooltip: classification.tooltip)
        }
        return ui(destination: packet.to?.call ?? "", info: packet.info,
                  text: packet.infoText ?? "")
    }

    /// A UI frame: APRS first, then the terminal's own reading of the text.
    static func ui(destination: String, info: Data, text: String) -> PacketTypeTag {
        if let digest = APRSDigest.parse(destination: destination, info: info) {
            return aprs(digest)
        }
        return plain(destination: destination, text: text)
    }

    /// An APRS frame, by its data type (APRS 1.01 chapter 5), decoded by the
    /// same parsers the terminal and the map use.
    static func aprs(_ digest: APRSDigest) -> PacketTypeTag {
        switch digest {
        case .position(let report):
            if report.weather != nil {
                return PacketTypeTag(label: "WX", tooltip: "APRS weather report with the station's position.")
            }
            if report.kind == .micE {
                return PacketTypeTag(label: "MIC-E", tooltip: "APRS position in Mic-E form, packed partly into the destination address. Usually a mobile or handheld radio.")
            }
            return PacketTypeTag(label: "POS", tooltip: "APRS position report.")
        case .weather:
            return PacketTypeTag(label: "WX", tooltip: "APRS weather report without a position.")
        case .object(let object):
            switch object.kind {
            case .object:
                return PacketTypeTag(label: "OBJ", tooltip: "APRS object: a point on the map placed by the sender, with a name and a time.")
            case .item:
                return PacketTypeTag(label: "ITEM", tooltip: "APRS item: a point on the map placed by the sender, with a name and no time.")
            }
        case .message(let inbound):
            switch inbound {
            case .message(_, let text, _):
                if isTelemetryDefinition(text) {
                    return PacketTypeTag(label: "TLM", tooltip: "APRS telemetry setup: the names, units, scaling or bit meanings for this station's telemetry, sent as a message to itself.")
                }
                return PacketTypeTag(label: "MSG", tooltip: "APRS text message.")
            case .ack:
                return PacketTypeTag(label: "MSG ACK", tooltip: "APRS acknowledgment: the addressee got a message.")
            case .reject:
                return PacketTypeTag(label: "MSG REJ", tooltip: "APRS reject: the addressee refused a message.")
            case .bulletin:
                return PacketTypeTag(label: "BLN", tooltip: "APRS bulletin or announcement, addressed to everyone.")
            case .directedQuery, .generalQuery:
                return PacketTypeTag(label: "QUERY", tooltip: "APRS query asking stations to report something, such as their position.")
            }
        case .telemetry:
            return PacketTypeTag(label: "TLM", tooltip: "APRS telemetry report: raw channel readings (T#).")
        case .status:
            return PacketTypeTag(label: "STATUS", tooltip: "APRS status report: a line of free text from the station.")
        }
    }

    /// `PARM.`, `UNIT.`, `EQNS.` or `BITS.`: the messages that define a
    /// station's telemetry (see `APRSTelemetry.parseDefinition`).
    static func isTelemetryDefinition(_ text: String) -> Bool {
        ["PARM.", "UNIT.", "EQNS.", "BITS."].contains { text.hasPrefix($0) }
    }

    /// A UI frame that is not APRS: an ID, a mail notice, or some other
    /// broadcast. Same words as the terminal's ID, MAIL and BCN chips.
    static func plain(destination: String, text: String) -> PacketTypeTag {
        let to = destination.trimmingCharacters(in: .whitespaces).uppercased()
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if to == "ID" || body == "ID" || body.hasPrefix("ID ") || body.hasPrefix("ID:") {
            return PacketTypeTag(label: "ID", tooltip: "Station identification.")
        }
        if to == "MAIL" || body.hasPrefix("MAIL FOR:") || body.hasPrefix("MAIL:") || body.hasPrefix("MAIL ") {
            return PacketTypeTag(label: "MAIL", tooltip: "Mail notice from a BBS.")
        }
        return PacketTypeTag(label: PacketClassification.uiBeacon.badge,
                             tooltip: PacketClassification.uiBeacon.tooltip)
    }
}
