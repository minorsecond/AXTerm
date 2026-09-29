import XCTest
@testable import AXTerm

final class WinlinkCMSClientTests: XCTestCase {

    /// URLProtocol stub capturing requests and replaying canned responses.
    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var lastRequestURL: URL?
        nonisolated(unsafe) static var responseData = Data()
        nonisolated(unsafe) static var responseStatus = 200
        /// Path -> body, for the calls that make more than one request.
        nonisolated(unsafe) static var responsesByPath: [String: Data] = [:]
        nonisolated(unsafe) static var requests: [(method: String, path: String, body: Data)] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequestURL = request.url
            // URLProtocol hands a POST body over as a stream.
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    body.append(contentsOf: buffer[0..<read])
                }
                stream.close()
            }
            Self.requests.append((request.httpMethod ?? "GET", request.url?.path ?? "", body))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: Self.responseStatus,
                httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let path = request.url?.path ?? ""
            client?.urlProtocol(self, didLoad: Self.responsesByPath[path] ?? Self.responseData)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeClient(key: String = "TESTKEY123") -> WinlinkCMSClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return WinlinkCMSClient(
            accessKey: key,
            session: URLSession(configuration: config),
            now: { Date(timeIntervalSince1970: 1_000_000) })
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.lastRequestURL = nil
        StubURLProtocol.responseData = Data()
        StubURLProtocol.responseStatus = 200
        StubURLProtocol.responsesByPath = [:]
        StubURLProtocol.requests = []
    }

    // MARK: - Password validation

    func testValidPasswordIsAccepted() async throws {
        StubURLProtocol.responseData = Data(#"{"IsValid":true,"ResponseStatus":{}}"#.utf8)
        let verdict = try await makeClient().validatePassword(callsign: "K0EPI-7", password: "SECRET99")
        XCTAssertEqual(verdict, .accepted)
    }

    /// The password must ride in the body. A query string is logged by
    /// every proxy and server on the way.
    func testPasswordIsPostedInTheBodyNotTheURL() async throws {
        StubURLProtocol.responseData = Data(#"{"IsValid":true}"#.utf8)
        _ = try await makeClient().validatePassword(callsign: "K0EPI-7", password: "SECRET99")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/account/password/validate")
        let url = try XCTUnwrap(StubURLProtocol.lastRequestURL?.absoluteString)
        XCTAssertFalse(url.contains("SECRET99"), url)
        XCTAssertTrue(url.contains("Key=TESTKEY123"), url)
        XCTAssertTrue(String(decoding: request.body, as: UTF8.self).contains("SECRET99"))
    }

    /// Winlink accounts belong to the base call; the SSID we connect with
    /// is not part of the account.
    func testSSIDIsStrippedBeforeAsking() async throws {
        StubURLProtocol.responseData = Data(#"{"IsValid":true}"#.utf8)
        _ = try await makeClient().validatePassword(callsign: "k0epi-7", password: "x")

        let body = String(decoding: try XCTUnwrap(StubURLProtocol.requests.first).body, as: UTF8.self)
        XCTAssertTrue(body.contains("\"Callsign\":\"K0EPI\""), body)
    }

    /// The CMS answers a wrong password and a missing account identically;
    /// the client asks the follow-up so the operator knows which to fix.
    func testWrongPasswordOnAnExistingAccountIsRejected() async throws {
        StubURLProtocol.responsesByPath = [
            "/account/password/validate": Data(#"{"IsValid":false,"ResponseStatus":{}}"#.utf8),
            "/account/exists": Data(#"{"CallsignExists":true,"Blocked":false}"#.utf8),
        ]
        let verdict = try await makeClient().validatePassword(callsign: "K0EPI", password: "WRONG")
        XCTAssertEqual(verdict, .rejected)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testUnknownAccountIsDistinguishedFromAWrongPassword() async throws {
        StubURLProtocol.responsesByPath = [
            "/account/password/validate": Data(#"{"IsValid":false}"#.utf8),
            "/account/exists": Data(#"{"CallsignExists":false,"Blocked":false}"#.utf8),
        ]
        let verdict = try await makeClient().validatePassword(callsign: "N0CALL", password: "x")
        XCTAssertEqual(verdict, .noSuchAccount)
    }

    func testBlockedAccountIsReportedAsBlocked() async throws {
        StubURLProtocol.responsesByPath = [
            "/account/password/validate": Data(#"{"IsValid":false}"#.utf8),
            "/account/exists": Data(#"{"CallsignExists":true,"Blocked":true}"#.utf8),
        ]
        let verdict = try await makeClient().validatePassword(callsign: "K0EPI", password: "x")
        XCTAssertEqual(verdict, .accountBlocked)
    }

    /// A 400 must not be read as "the password is wrong" — that would put
    /// a red cross next to a perfectly good password.
    func testServiceErrorThrowsRatherThanRejecting() async {
        StubURLProtocol.responseStatus = 400
        StubURLProtocol.responseData = Data(#"""
        {"IsValid":false,"ResponseStatus":{"ErrorCode":"InvalidAccessKey","Message":"Invalid access key for this operation"}}
        """#.utf8)
        do {
            _ = try await makeClient().validatePassword(callsign: "K0EPI", password: "x")
            XCTFail("expected a service error")
        } catch let WinlinkCMSError.serviceError(message) {
            XCTAssertTrue(message.contains("Invalid access key"), message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Error text goes to logs; neither credential may ride along.
    func testCredentialsAreScrubbedFromServiceErrors() async {
        StubURLProtocol.responseStatus = 400
        StubURLProtocol.responseData = Data(#"""
        {"ResponseStatus":{"ErrorCode":"Bad","Message":"key TESTKEY123 and password SECRET99 refused"}}
        """#.utf8)
        do {
            _ = try await makeClient().validatePassword(callsign: "K0EPI", password: "SECRET99")
            XCTFail("expected a service error")
        } catch let WinlinkCMSError.serviceError(message) {
            XCTAssertFalse(message.contains("TESTKEY123"), message)
            XCTAssertFalse(message.contains("SECRET99"), message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Gateway proximity

    func testGatewayProximityBuildsCorrectRequest() async throws {
        StubURLProtocol.responseData = Data(#"{"Gateways":[]}"#.utf8)
        let client = makeClient()
        _ = try await client.gatewayProximity(gridSquare: "DM79lr", maxDistanceMiles: 120, historyHours: 6)

        let url = try XCTUnwrap(StubURLProtocol.lastRequestURL?.absoluteString)
        // The community key is only authorized for the status listing;
        // proximity math happens locally.
        XCTAssertTrue(url.contains("/gateway/status.json"), url)
        XCTAssertTrue(url.contains("ServiceCodes=PUBLIC"), url)
        XCTAssertTrue(url.contains("HistoryHours=6"), url)
        XCTAssertTrue(url.contains("Key=TESTKEY123"), url)
        XCTAssertTrue(url.contains("format=json"), url)
    }

    func testGatewayProximityComputesDistanceAndFiltersPacketChannels() async throws {
        // Origin DM79 center is ~39.5N 105.0W. KE7XO sits ~0.5° north
        // (~34.5 mi); the VARA-only gateway must be dropped.
        StubURLProtocol.responseData = Data("""
        {"Gateways":[
          {"Callsign":"KE7XO-10","Latitude":40.0,"Longitude":-105.0,
           "LastStatus":"Sun, 23 Aug 2026 11:45:00 UTC",
           "GatewayChannels":[
             {"SupportedModes":"Packet 1200","Frequency":145050000,"Gridsquare":"DN70","Baud":"0","ServiceCode":"PUBLIC"},
             {"SupportedModes":"VARA FM WIDE","Frequency":145220000,"Gridsquare":"DN70","Baud":"0","ServiceCode":"PUBLIC"}
           ]},
          {"Callsign":"FARAWAY-10","Latitude":10.0,"Longitude":-50.0,
           "GatewayChannels":[
             {"SupportedModes":"Packet 9600","Frequency":144970000,"Gridsquare":"AA00","Baud":"0","ServiceCode":"PUBLIC"}
           ]},
          {"Callsign":"NOPOS-10","Latitude":0,"Longitude":0,
           "GatewayChannels":[{"SupportedModes":"Packet 1200","Frequency":144910000}]}
        ]}
        """.utf8)

        let client = makeClient()
        let stations = try await client.gatewayProximity(gridSquare: "DM79", maxDistanceMiles: 500, historyHours: 6)

        XCTAssertEqual(stations.map(\.callsign), ["KE7XO-10"], "VARA channel, distant and position-less gateways filtered")
        XCTAssertEqual(stations[0].frequencyHz, 145_050_000)
        XCTAssertEqual(stations[0].baud, "1200", "baud derived from the mode string when Baud is 0")
        XCTAssertEqual(stations[0].distanceMiles, 34.5, accuracy: 3)
        XCTAssertNotNil(stations[0].lastSeenAt)
        XCTAssertEqual(stations[0].fetchedAt, Date(timeIntervalSince1970: 1_000_000))
    }

    func testFourHundredWithServiceStackBodySurfacesRealError() async {
        StubURLProtocol.responseStatus = 400
        StubURLProtocol.responseData = Data("""
        {"Gateways":[],"ResponseStatus":{"ErrorCode":"InvalidAccessKey","Message":"Invalid access key for this operation"}}
        """.utf8)
        let client = makeClient()
        do {
            _ = try await client.gatewayProximity(gridSquare: "DM79", maxDistanceMiles: 0, historyHours: 6)
            XCTFail("expected serviceError")
        } catch let WinlinkCMSError.serviceError(message) {
            XCTAssertTrue(message.contains("Invalid access key"), message)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testGatewayProximityRejectsInvalidGrid() async {
        let client = makeClient()
        do {
            _ = try await client.gatewayProximity(gridSquare: "not-a-grid", maxDistanceMiles: 0, historyHours: 6)
            XCTFail("expected invalidGridSquare")
        } catch {
            XCTAssertEqual(error as? WinlinkCMSError, .invalidGridSquare("not-a-grid"))
        }
        XCTAssertNil(StubURLProtocol.lastRequestURL, "no request should be made for a bad grid")
    }

    // MARK: - Catalog

    func testCatalogParsesItems() async throws {
        StubURLProtocol.responseData = Data("""
        {"Inquiries":[
          {"InquiryId":"WX_CONUS","Category":"Weather","Subject":"CONUS Forecast",
           "Url":"http://example.com","Lifetime":1,"SizeEstimate":4200,"Enabled":true,"DownloadCount":99},
          {"InquiryId":"","Category":"Broken"}
        ]}
        """.utf8)

        let client = makeClient()
        let items = try await client.inquiriesCatalog()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].inquiryId, "WX_CONUS")
        XCTAssertEqual(items[0].category, "Weather")
        XCTAssertEqual(items[0].sizeEstimate, 4200)
        XCTAssertTrue(items[0].enabled)
    }

    // MARK: - Errors

    func testHTTPErrorSurfacesStatus() async {
        StubURLProtocol.responseStatus = 403
        let client = makeClient()
        do {
            _ = try await client.inquiriesCatalog()
            XCTFail("expected httpError")
        } catch {
            XCTAssertEqual(error as? WinlinkCMSError, .httpError(status: 403))
        }
    }

    func testServiceErrorNeverContainsAccessKey() async {
        StubURLProtocol.responseData = Data("""
        {"ResponseStatus":{"ErrorCode":"Unauthorized","Message":"Bad key TESTKEY123 rejected"}}
        """.utf8)
        let client = makeClient()
        do {
            _ = try await client.inquiriesCatalog()
            XCTFail("expected serviceError")
        } catch let WinlinkCMSError.serviceError(message) {
            XCTAssertFalse(message.contains("TESTKEY123"), "key leaked into error: \(message)")
            XCTAssertTrue(message.contains("Bad key"), message)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testMissingKeyFailsFast() async {
        let client = makeClient(key: "")
        do {
            _ = try await client.inquiriesCatalog()
            XCTFail("expected missingAccessKey")
        } catch {
            XCTAssertEqual(error as? WinlinkCMSError, .missingAccessKey)
        }
    }

    func testMalformedJSONIsReported() async {
        StubURLProtocol.responseData = Data("this is not json".utf8)
        let client = makeClient()
        do {
            _ = try await client.inquiriesCatalog()
            XCTFail("expected malformedResponse")
        } catch {
            XCTAssertEqual(error as? WinlinkCMSError, .malformedResponse)
        }
    }
}
