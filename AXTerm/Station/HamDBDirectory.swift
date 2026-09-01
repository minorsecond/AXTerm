import Foundation

/// hamdb.org, as a `CallsignDirectory`.
///
/// The wire shape was captured live on 2026-08-24, and two details are
/// not guessable from documentation:
///
/// * The **versioned** path is required. `api.hamdb.org/{call}/json/{app}`
///   answers 302 with an empty body; `api.hamdb.org/v1/...` answers.
/// * A miss is **HTTP 200** with every field set to the literal string
///   `"NOT_FOUND"` — `grid`, `lat`, `name`, all of them. Parsed naively
///   that yields a station called NOT_FOUND in grid NOT_FOUND, so the
///   sentinel has to be detected explicitly rather than trusted to fail
///   at conversion.
///
/// Decoding is separated from fetching so the awkward parts are testable
/// against captured payloads with no network involved.
enum CallsignDirectoryError: Error {
    /// 429 or 5xx — the far end wants us to stop, not to be told again.
    case serverUnavailable(status: Int)
}
nonisolated struct HamDBDirectory: CallsignDirectory {

    let sourceName = "HamDB"
    let requiresNetwork = true

    /// Sent as the application name in the URL; hamdb asks callers to
    /// identify themselves.
    var appName: String = "AXTerm"
    var session: URLSession = .shared

    /// The sentinel hamdb returns for every field of a missing callsign.
    static let notFound = "NOT_FOUND"

    func url(for callsign: String) -> URL? {
        let call = CallsignQuery.normalize(callsign)
        guard !call.isEmpty else { return nil }
        return URL(string: "https://api.hamdb.org/v1/\(call)/json/\(appName)")
    }

    func lookup(_ callsign: String) async throws -> CallsignRecord? {
        guard let url = url(for: callsign) else { return nil }
        let (data, response) = try await session.data(from: url)
        // A throttle or an outage is not a miss: a miss is cached as
        // "attempted" and never retried this launch, which is exactly
        // wrong for "try again in a minute". Surface it as an error so
        // the service can open its breaker instead.
        if let http = response as? HTTPURLResponse,
           http.statusCode == 429 || http.statusCode >= 500 {
            throw CallsignDirectoryError.serverUnavailable(status: http.statusCode)
        }
        return Self.decode(data, now: Date())
    }

    // MARK: - Decoding

    private struct Payload: Decodable {
        struct Body: Decodable {
            struct Callsign: Decodable {
                var call: String?
                var `class`: String?
                var expires: String?
                var grid: String?
                var lat: String?
                var lon: String?
                var fname: String?
                var name: String?
                /// The street line. Decoded because it is the only way to
                /// tell a house from a post office box, and a PO box means
                /// the coordinate is a post office.
                var addr1: String?
                var addr2: String?
                var state: String?
                var country: String?
            }
            struct Messages: Decodable { var status: String? }
            var callsign: Callsign
            var messages: Messages?
        }
        var hamdb: Body
    }

    /// Returns nil for a miss or an unparseable body — never a record
    /// full of sentinels.
    static func decode(_ data: Data, now: Date) -> CallsignRecord? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let body = payload.hamdb
        // The status field is the reliable signal; the per-field
        // sentinels are the backstop for a source that forgets to set it.
        if let status = body.messages?.status, status.uppercased() != "OK" { return nil }

        let entry = body.callsign
        guard let call = clean(entry.call), !call.isEmpty else { return nil }

        // hamdb prints the name in two fields and neither is reliably
        // capitalised — "WAYNE" and "Robert" both occur.
        let name = [clean(entry.fname), clean(entry.name)]
            .compactMap { $0 }
            .joined(separator: " ")

        let record = CallsignRecord(
            callsign: call.uppercased(),
            name: name.isEmpty ? nil : name.capitalized,
            gridSquare: clean(entry.grid),
            latitude: clean(entry.lat).flatMap(Double.init),
            longitude: clean(entry.lon).flatMap(Double.init),
            street: clean(entry.addr1),
            locality: clean(entry.addr2)?.capitalized,
            state: clean(entry.state),
            country: clean(entry.country),
            licenseClass: clean(entry.class),
            expires: clean(entry.expires),
            source: "HamDB",
            fetchedAt: now)
        return record.isEmpty ? nil : record
    }

    /// Maps the sentinel and empty strings onto nil, so "absent" has one
    /// representation rather than three.
    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.uppercased() != notFound
        else { return nil }
        return trimmed
    }
}
