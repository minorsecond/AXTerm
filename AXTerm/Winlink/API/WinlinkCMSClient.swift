import Foundation

/// Client for the Winlink CMS web services (nearby-gateway lookup and
/// the inquiries catalog).
///
/// The access key is a credential: it goes into the request only, and
/// error text is scrubbed so the key can never leak into logs or Sentry
/// breadcrumbs.
nonisolated protocol CMSClienting: Sendable {
    func gatewayProximity(gridSquare: String, maxDistanceMiles: Int, historyHours: Int) async throws -> [WinlinkRMSStationRecord]
    func inquiriesCatalog() async throws -> [WinlinkCatalogItemRecord]
}

nonisolated enum WinlinkCMSError: Error, Equatable {
    case missingAccessKey
    case invalidGridSquare(String)
    case httpError(status: Int)
    case serviceError(message: String)
    case malformedResponse
}

nonisolated final class WinlinkCMSClient: CMSClienting, @unchecked Sendable {

    /// The access key published in the open-source Pat client's repo;
    /// used as the out-of-the-box default and overridable in Settings.
    static let defaultAccessKey = "1880278F11684B358F36845615BD039A"
    static let defaultBaseURL = URL(string: "https://api.winlink.org")!

    private let baseURL: URL
    private let accessKey: String
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(
        accessKey: String = WinlinkCMSClient.defaultAccessKey,
        baseURL: URL = WinlinkCMSClient.defaultBaseURL,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accessKey = accessKey
        self.baseURL = baseURL
        self.session = session
        self.now = now
    }

    // MARK: - Endpoints

    func gatewayProximity(gridSquare: String, maxDistanceMiles: Int, historyHours: Int) async throws -> [WinlinkRMSStationRecord] {
        guard Maidenhead.isValid(gridSquare) else {
            throw WinlinkCMSError.invalidGridSquare(gridSquare)
        }
        let response: CMSGatewayProximityResponse = try await get(
            path: "gateway/proximity",
            query: [
                "GridSquare": gridSquare,
                "OperatingMode": "Packet",
                "ServiceCodes": "PUBLIC",
                "MaxDistance": String(maxDistanceMiles),
                "HistoryHours": String(historyHours),
            ])
        try checkServiceStatus(response.ResponseStatus)
        let fetchedAt = now()
        return (response.GatewayList ?? []).compactMap { $0.stationRecord(fetchedAt: fetchedAt) }
    }

    func inquiriesCatalog() async throws -> [WinlinkCatalogItemRecord] {
        let response: CMSInquiriesCatalogResponse = try await get(path: "inquiries/catalog", query: [:])
        try checkServiceStatus(response.ResponseStatus)
        let fetchedAt = now()
        return (response.Inquiries ?? []).compactMap { $0.catalogRecord(fetchedAt: fetchedAt) }
    }

    // MARK: - Plumbing

    private func get<Response: Decodable>(path: String, query: [String: String]) async throws -> Response {
        guard !accessKey.isEmpty else { throw WinlinkCMSError.missingAccessKey }

        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "format", value: "json"))
        items.append(URLQueryItem(name: "Key", value: accessKey))
        components.queryItems = items

        let (data, urlResponse) = try await session.data(from: components.url!)
        if let http = urlResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WinlinkCMSError.httpError(status: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WinlinkCMSError.malformedResponse
        }
    }

    private func checkServiceStatus(_ status: CMSResponseStatus?) throws {
        guard let status, status.ErrorCode != nil || status.Message != nil else { return }
        // Scrub the key defensively: service error text must never carry
        // the credential into logs.
        let message = (status.Message ?? status.ErrorCode ?? "unknown service error")
            .replacingOccurrences(of: accessKey, with: "•••")
        throw WinlinkCMSError.serviceError(message: message)
    }
}
