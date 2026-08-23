import Foundation

/// DTOs for the Winlink CMS web services (api.winlink.org, JSON).

nonisolated struct CMSGatewayProximityResponse: Codable, Sendable {
    var GatewayList: [CMSGateway]?
    var ResponseStatus: CMSResponseStatus?
}

nonisolated struct CMSGateway: Codable, Sendable {
    var Callsign: String?
    var BaseCallsign: String?
    var Gridsquare: String?
    /// Hertz.
    var Frequency: Double?
    var Mode: Int?
    var Baud: String?
    var ServiceCode: String?
    /// Miles from the queried grid square.
    var Distance: Double?
    /// Degrees true.
    var Heading: Double?
    var LastStatus: String?
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

nonisolated struct CMSResponseStatus: Codable, Sendable {
    var ErrorCode: String?
    var Message: String?
}

// MARK: - Mapping to cache records

extension CMSGateway {
    func stationRecord(fetchedAt: Date) -> WinlinkRMSStationRecord? {
        guard let callsign = Callsign?.trimmingCharacters(in: .whitespaces), !callsign.isEmpty,
              let frequency = Frequency, frequency > 0
        else { return nil }

        let lastSeen: Date? = LastStatus.flatMap { text in
            // RFC1123-ish timestamps; tolerate absence.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter.date(from: text)
        }

        return WinlinkRMSStationRecord(
            callsign: callsign,
            gridSquare: Gridsquare ?? "",
            frequencyHz: Int(frequency),
            modeName: "Packet",
            baud: Baud ?? "",
            serviceCode: ServiceCode ?? "PUBLIC",
            distanceMiles: Distance ?? 0,
            headingDegrees: Heading ?? 0,
            lastSeenAt: lastSeen,
            fetchedAt: fetchedAt)
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
