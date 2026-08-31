import Foundation

/// DTOs for the Winlink CMS web services (api.winlink.org, JSON).
///
/// Note: the community access key (Pat's) is only authorized for
/// `/gateway/status.json`, `/account/password/validate` and
/// `/account/exists` — the proximity and catalog operations return
/// `InvalidAccessKey` (HTTP 400). Distance/bearing are therefore computed
/// locally from each gateway's latitude/longitude.

nonisolated struct CMSGatewayStatusResponse: Codable, Sendable {
    var Gateways: [CMSGateway]?
    var ResponseStatus: CMSResponseStatus?
}

nonisolated struct CMSGateway: Codable, Sendable {
    var Callsign: String?
    var BaseCallsign: String?
    var Latitude: Double?
    var Longitude: Double?
    var HoursSinceStatus: Int?
    /// RFC1123-style, e.g. "Sun, 23 Aug 2026 11:45:00 UTC".
    var LastStatus: String?
    var Comments: String?
    var GatewayChannels: [CMSGatewayChannel]?
}

nonisolated struct CMSGatewayChannel: Codable, Sendable {
    /// e.g. "Packet 1200", "Packet 9600", "VARA FM WIDE", "ARDOP 2000".
    var SupportedModes: String?
    var Mode: Int?
    var Gridsquare: String?
    /// Hertz.
    var Frequency: Double?
    var Baud: String?
    var OperatingHours: String?
    var ServiceCode: String?
}

nonisolated struct CMSInquiriesCatalogResponse: Codable, Sendable {
    var Inquiries: [CMSInquiry]?
    var ResponseStatus: CMSResponseStatus?
}

nonisolated struct CMSInquiry: Codable, Sendable {
    var InquiryId: String?
    var Category: String?
    var Subject: String?
    var Process: String?
    var Url: String?
    /// Days the product stays fresh on the CMS.
    var Lifetime: Int?
    /// Approximate response size in bytes.
    var SizeEstimate: Int?
    var Enabled: Bool?
    var DownloadCount: Int?
}

nonisolated struct CMSPasswordValidateRequest: Codable, Sendable {
    var Callsign: String
    var Password: String
}

nonisolated struct CMSPasswordValidateResponse: Codable, Sendable {
    var IsValid: Bool?
    var ResponseStatus: CMSResponseStatus?
}

nonisolated struct CMSAccountExistsRequest: Codable, Sendable {
    var Callsign: String
}

nonisolated struct CMSAccountExistsResponse: Codable, Sendable {
    var CallsignExists: Bool?
    var Blocked: Bool?
    var ResponseStatus: CMSResponseStatus?
}

nonisolated struct CMSResponseStatus: Codable, Sendable {
    var ErrorCode: String?
    var Message: String?
}

/// Minimal envelope for decoding the ResponseStatus out of 4xx bodies.
nonisolated struct CMSErrorEnvelope: Codable, Sendable {
    var ResponseStatus: CMSResponseStatus?
}

// MARK: - Mapping to cache records

extension CMSGateway {

    static let lastStatusFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Builds one station row per *packet* channel of this gateway, with
    /// distance and bearing computed from the user's location.
    func packetStationRecords(
        from origin: Maidenhead.Coordinate,
        fetchedAt: Date
    ) -> [WinlinkRMSStationRecord] {
        guard let callsign = Callsign?.trimmingCharacters(in: .whitespaces), !callsign.isEmpty,
              let latitude = Latitude, let longitude = Longitude,
              latitude != 0 || longitude != 0
        else { return [] }

        let position = Maidenhead.Coordinate(latitude: latitude, longitude: longitude)
        let distanceMiles = Maidenhead.haversineKm(origin, position) * 0.621371
        let bearing = Maidenhead.bearingDegrees(from: origin, to: position)
        let lastSeen = LastStatus.flatMap { Self.lastStatusFormatter.date(from: $0) }

        return (GatewayChannels ?? []).compactMap { channel in
            guard let modes = channel.SupportedModes?.lowercased(),
                  modes.contains("packet"),
                  let frequency = channel.Frequency, frequency > 0
            else { return nil }

            // "Packet 1200" style — prefer the mode string's rate over the
            // often-zero Baud field.
            let baud: String
            if let rate = modes.split(separator: " ").last, Int(rate) != nil {
                baud = String(rate)
            } else if let rawBaud = channel.Baud, rawBaud != "0", !rawBaud.isEmpty {
                baud = rawBaud
            } else {
                baud = "1200"
            }

            return WinlinkRMSStationRecord(
                callsign: callsign,
                gridSquare: channel.Gridsquare ?? "",
                frequencyHz: Int(frequency),
                modeName: channel.SupportedModes ?? "Packet",
                baud: baud,
                serviceCode: channel.ServiceCode ?? "PUBLIC",
                distanceMiles: distanceMiles,
                headingDegrees: bearing ?? 0,
                lastSeenAt: lastSeen,
                fetchedAt: fetchedAt)
        }
    }
}

extension CMSInquiry {
    func catalogRecord(fetchedAt: Date) -> WinlinkCatalogItemRecord? {
        guard let inquiryId = InquiryId?.trimmingCharacters(in: .whitespaces), !inquiryId.isEmpty
        else { return nil }
        return WinlinkCatalogItemRecord(
            inquiryId: inquiryId,
            category: Category ?? "Uncategorized",
            subject: Subject ?? "",
            url: Url ?? "",
            lifetimeDays: Lifetime ?? 0,
            sizeEstimate: SizeEstimate ?? 0,
            enabled: Enabled ?? true,
            fetchedAt: fetchedAt)
    }
}
