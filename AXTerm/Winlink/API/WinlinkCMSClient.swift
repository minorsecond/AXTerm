import Foundation

/// Client for the Winlink CMS web services (nearby-gateway lookup, the
/// inquiries catalog, and account password validation).
///
/// The access key is a credential: it goes into the request only, and
/// error text is scrubbed so the key can never leak into logs or Sentry
/// breadcrumbs.
nonisolated protocol CMSClienting: Sendable {
    func gatewayProximity(gridSquare: String, maxDistanceMiles: Int, historyHours: Int) async throws -> [WinlinkRMSStationRecord]
    func inquiriesCatalog() async throws -> [WinlinkCatalogItemRecord]
    func validatePassword(callsign: String, password: String) async throws -> WinlinkPasswordVerdict
}

/// What the CMS says about a callsign/password pair.
///
/// `.rejected` and `.noSuchAccount` both arrive from the service as a bare
/// `IsValid: false`, but they need opposite fixes — one is the password,
/// the other is the callsign — so they are separated here.
nonisolated enum WinlinkPasswordVerdict: Equatable, Sendable {
    case accepted
    case rejected
    case noSuchAccount
    case accountBlocked
}

nonisolated enum WinlinkCMSError: Error, Equatable {
    case missingAccessKey
    case invalidGridSquare(String)
    case invalidCallsign(String)
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

    /// Fetches nearby packet gateways.
    ///
    /// Uses `/gateway/status.json` (the only gateway operation the
    /// community access key is authorized for) and computes distance and
    /// bearing locally from each gateway's reported coordinates.
    func gatewayProximity(gridSquare: String, maxDistanceMiles: Int, historyHours: Int) async throws -> [WinlinkRMSStationRecord] {
        guard let origin = Maidenhead.center(of: gridSquare) else {
            throw WinlinkCMSError.invalidGridSquare(gridSquare)
        }
        let response: CMSGatewayStatusResponse = try await get(
            path: "gateway/status.json",
            query: [
                "ServiceCodes": "PUBLIC",
                "HistoryHours": String(historyHours),
            ])
        try checkServiceStatus(response.ResponseStatus)

        let fetchedAt = now()
        var stations = (response.Gateways ?? []).flatMap {
            $0.packetStationRecords(from: origin, fetchedAt: fetchedAt)
        }
        if maxDistanceMiles > 0 {
            stations = stations.filter { $0.distanceMiles <= Double(maxDistanceMiles) }
        }
        return stations.sorted {
            ($0.distanceMiles, $0.callsign, $0.frequencyHz) < ($1.distanceMiles, $1.callsign, $1.frequencyHz)
        }
    }

    func inquiriesCatalog() async throws -> [WinlinkCatalogItemRecord] {
        let response: CMSInquiriesCatalogResponse = try await get(path: "inquiries/catalog", query: [:])
        try checkServiceStatus(response.ResponseStatus)
        let fetchedAt = now()
        return (response.Inquiries ?? []).compactMap { $0.catalogRecord(fetchedAt: fetchedAt) }
    }

    /// Asks the CMS whether this password is the one on the account.
    ///
    /// This is the check the `;PR:` secure-login handshake will make on
    /// the air, done over HTTPS where the answer is a sentence instead of
    /// a disconnect. The password rides in the POST body, never the query
    /// string, and is scrubbed out of any error text.
    ///
    /// Winlink accounts belong to the base callsign, so an SSID is
    /// stripped: `K0EPI-7` validates against `K0EPI`.
    func validatePassword(callsign: String, password: String) async throws -> WinlinkPasswordVerdict {
        guard let account = Callsign(callsign)?.base, !account.isEmpty else {
            throw WinlinkCMSError.invalidCallsign(callsign)
        }

        let response: CMSPasswordValidateResponse = try await post(
            path: "account/password/validate",
            body: CMSPasswordValidateRequest(Callsign: account, Password: password),
            secret: password)
        try checkServiceStatus(response.ResponseStatus, secret: password)
        if response.IsValid == true { return .accepted }

        // A wrong password and an account that does not exist are the same
        // `IsValid: false` here. Ask which it was — the operator needs to
        // know whether to fix the password or the callsign.
        let existence: CMSAccountExistsResponse = try await post(
            path: "account/exists",
            body: CMSAccountExistsRequest(Callsign: account),
            secret: nil)
        try checkServiceStatus(existence.ResponseStatus)
        if existence.CallsignExists != true { return .noSuchAccount }
        if existence.Blocked == true { return .accountBlocked }
        return .rejected
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
        return try decode(data: data, urlResponse: urlResponse, secret: nil)
    }

    /// POST with a JSON body. Operations that carry a credential use this:
    /// a query string lands in server logs and proxy caches, a body does not.
    private func post<Body: Encodable, Response: Decodable>(
        path: String, body: Body, secret: String?
    ) async throws -> Response {
        guard !accessKey.isEmpty else { throw WinlinkCMSError.missingAccessKey }

        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "Key", value: accessKey),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, urlResponse) = try await session.data(for: request)
        return try decode(data: data, urlResponse: urlResponse, secret: secret)
    }

    private func decode<Response: Decodable>(
        data: Data, urlResponse: URLResponse, secret: String?
    ) throws -> Response {
        if let http = urlResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // ServiceStack errors ride a JSON body even on 4xx — surface
            // the real reason (e.g. InvalidAccessKey) instead of a bare code.
            if let envelope = try? JSONDecoder().decode(CMSErrorEnvelope.self, from: data),
               let status = envelope.ResponseStatus,
               status.ErrorCode != nil || status.Message != nil {
                try checkServiceStatus(status, secret: secret)
            }
            throw WinlinkCMSError.httpError(status: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WinlinkCMSError.malformedResponse
        }
    }

    private func checkServiceStatus(_ status: CMSResponseStatus?, secret: String? = nil) throws {
        guard let status, status.ErrorCode != nil || status.Message != nil else { return }
        // Scrub the credentials defensively: service error text must never
        // carry the key — or the account password — into logs.
        var message = (status.Message ?? status.ErrorCode ?? "unknown service error")
            .replacingOccurrences(of: accessKey, with: "•••")
        if let secret, !secret.isEmpty {
            message = message.replacingOccurrences(of: secret, with: "•••")
        }
        throw WinlinkCMSError.serviceError(message: message)
    }
}
