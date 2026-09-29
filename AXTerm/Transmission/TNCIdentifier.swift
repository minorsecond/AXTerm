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
        guard frame.count > 1 else { return nil }
        let payload = frame.dropFirst()
        // The prefix is optional. Direwolf 1.8 answers the `TNC:` query with
        // the bare string `DIREWOLF 1.8` and echoes nothing — measured off the
        // air 2026-09-10, `06 44 49 52 45 57 4f 4c 46 20 31 2e 38`. Requiring
        // the echo threw that answer away and filed it as unknown Mobilinkd
        // telemetry, so a Direwolf link showed no identity at all.
        let prefix = Data("TNC:".utf8)
        let rest = payload.starts(with: prefix) ? payload.dropFirst(prefix.count) : payload
        guard !rest.isEmpty else { return nil }
        // Mobilinkd telemetry rides the same SetHardware command and must fall
        // through untouched. Its second byte is a binary opcode — 0x04 poll
        // input level, 0x06 battery, 0x02 input gain — never printable, so
        // "all printable" is what separates a spoken name from a reading.
        // Without the prefix to lean on, this guard is the only thing that does.
        let isText = rest.allSatisfy { (0x20...0x7E).contains($0) || $0 == 0x00 || $0 == 0x0A || $0 == 0x0D }
        guard isText else { return nil }
        guard let text = String(data: rest, encoding: .utf8)
                ?? String(data: rest, encoding: .ascii) else { return nil }
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        // A name has letters in it; a run of spaces or digits is not one.
        guard trimmed.contains(where: \.isLetter) else { return nil }
        return trimmed
    }

    static func isDirewolf(_ identity: String) -> Bool {
        identity.lowercased().contains("direwolf")
    }
}
