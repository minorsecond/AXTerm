//
//  TNCIdentifier.swift
//  AXTerm
//
//  The in-band KISS hardware query. A KISS TNC normally never says what
//  it is — but the SetHardware command (6) is defined as
//  hardware-dependent, and Direwolf answers a "TNC:" query on it with
//  its own name and version, over the same TCP link, transmitting
//  nothing on RF. Software or hardware that does not implement the
//  extension ignores the frame; the query is advisory by construction.
//

import Foundation

nonisolated enum TNCIdentifier {

    /// FEND, SetHardware on port 0, the question, FEND.
    static func queryFrame() -> Data {
        var frame = Data([0xC0, 0x06])
        frame.append(Data("TNC:".utf8))
        frame.append(0xC0)
        return frame
    }

    /// Parses a hardware-command frame (`[command byte, payload…]`, as
    /// the KISS parser hands them on) as an identity reply. Returns the
    /// identity ("direwolf 1.7"), or nil for anything else on the same
    /// command — Mobilinkd telemetry must fall through untouched.
    static func identity(fromTelemetryFrame frame: Data) -> String? {
        let prefix = Data("TNC:".utf8)
        guard frame.count > 1 + prefix.count else { return nil }
        let payload = frame.dropFirst()
        guard payload.prefix(prefix.count) == prefix else { return nil }
        let rest = payload.dropFirst(prefix.count)
        guard let text = String(data: rest, encoding: .utf8)
                ?? String(data: rest, encoding: .ascii) else { return nil }
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isDirewolf(_ identity: String) -> Bool {
        identity.lowercased().contains("direwolf")
    }
}
