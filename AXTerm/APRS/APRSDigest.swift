//
//  APRSDigest.swift
//  AXTerm
//
//  One decode of an APRS frame, for surfaces that want to say what a packet
//  means rather than print what it contained.
//
//  The console printed `packet.info` verbatim. For AX.25 that is the right
//  answer — a human can read a NET/ROM broadcast or a BBS prompt off the wire,
//  and the terminal is where you go to see exactly what was sent. APRS does
//  not survive the same treatment. A Mic-E position keeps its latitude in the
//  AX.25 *destination* field and the rest in bytes that are not text at all:
//
//      KF0KBL-1 → SYUUUU   `q[Qm"[>/`"E^}_4
//
//  Nobody reads that, and the row above draws `SYUUUU` as if it were a
//  callsign. A compressed report is no better. So on an APRS channel the
//  terminal was printing the one thing it could not print.
//
//  This is the decode, not the rendering: it returns the existing parsers'
//  own types rather than inventing parallel ones, so there is exactly one
//  implementation of "what is a Mic-E position" in the app and the console
//  cannot drift from the map. `APRSDigestLine` turns it into words.
//

import Foundation

/// What an APRS frame turned out to be, with whatever the parsers recovered.
///
/// Not `Hashable`: `APRSObjectReport` is not, and a digest is carried by
/// `ConsoleLine`, which hashes on its id rather than its contents.
nonisolated enum APRSDigest: Equatable, Sendable {
    /// A position report — uncompressed, compressed, or Mic-E. Carries the
    /// station's own weather when it is a weather station.
    case position(APRSReport)
    /// A weather report with no position (data type `_`), which many home
    /// stations send separately from their beacon.
    case weather(APRSWeather)
    /// An object or item placed by another station.
    case object(APRSObjectReport)
    /// The message class: messages, acks, rejects, bulletins, queries.
    case message(APRSMessage.Inbound)
    /// A `T#` telemetry report.
    case telemetry(APRSTelemetry.Frame)
    /// A status report (data type `>`).
    case status(String)

    /// Decode one frame, or nil if it is not APRS.
    ///
    /// `destination` is the AX.25 destination callsign, which Mic-E needs;
    /// `info` is the information field as bytes, never as text. The console's
    /// `infoText` has already trimmed control characters and given up on
    /// anything under three-quarters printable, which is exactly what a Mic-E
    /// payload is — so a digest built from that string would miss the frames
    /// that need it most.
    ///
    /// Order matters where data types overlap: an object report and a position
    /// both end in position data, and a weather-carrying position is a
    /// position first.
    static func parse(destination: String, info: Data) -> APRSDigest? {
        guard let dti = info.first else { return nil }

        if let object = APRSObjectReport.parse(info: info) { return .object(object) }
        if let message = APRSMessage.parse(info: info) { return .message(message) }
        if let report = APRSParser.parse(destination: destination, info: info) { return .position(report) }
        if let weather = APRSParser.parseWeather(info: info) { return .weather(weather) }
        if let frame = APRSTelemetry.parseFrame(info: info) { return .telemetry(frame) }
        if dti == UInt8(ascii: ">"), let text = statusText(info) { return .status(text) }
        return nil
    }

    /// `>` then the status, which may begin with a timestamp this does not
    /// try to separate — the receiver's own clock already answers "when", and
    /// a status is the operator's own words either way.
    private static func statusText(_ info: Data) -> String? {
        guard let text = String(data: info.dropFirst(), encoding: .ascii)
                ?? String(data: info.dropFirst(), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Where this frame says something is, when it says so at all.
    var coordinate: GreatCircle.Point? {
        switch self {
        case .position(let r): return GreatCircle.Point(latitude: r.latitude, longitude: r.longitude)
        case .object(let o): return GreatCircle.Point(latitude: o.latitude, longitude: o.longitude)
        case .weather, .message, .telemetry, .status: return nil
        }
    }

    /// The symbol to draw beside the line, when the frame carries one.
    var symbol: (table: Character, code: Character)? {
        switch self {
        case .position(let r): return (r.symbolTable, r.symbolCode)
        case .object(let o): return (o.symbolTable, o.symbolCode)
        case .weather, .message, .telemetry, .status: return nil
        }
    }

    /// Which console filter chip this belongs under.
    ///
    /// Reuses the classes that already exist rather than adding APRS-only
    /// ones. A position report *is* a beacon, and filing it as one is what
    /// makes the BCN chip able to quiet a busy APRS channel without also
    /// hiding the messages — which was the other half of the problem, because
    /// `detectMessageType` sorted every APRS frame over ten characters into
    /// DATA, so there was no way to see the conversation for the beacons.
    var messageClass: ConsoleLine.MessageType {
        switch self {
        case .position, .weather, .object, .telemetry, .status:
            return .beacon
        case .message(let inbound):
            switch inbound {
            case .message, .bulletin:
                return .data
            case .ack, .reject, .directedQuery, .generalQuery:
                // Protocol chatter about messages rather than messages, which
                // is what the CMD chip is for.
                return .prompt
            }
        }
    }
}
