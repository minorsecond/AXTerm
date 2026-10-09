import XCTest
@testable import AXTerm

/// The real network adapter for hazard feeds: an HTTP error is a failure,
/// not data, and a test run never reaches past loopback
/// (`AppEnvironment.mayConnect`).
final class URLSessionHazardFetcherTests: XCTestCase {

    /// Answers every request with the status and body set here.
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = Data()
        nonisolated(unsafe) static var requests = 0
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func fetcher() -> URLSessionHazardFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSessionHazardFetcher(session: URLSession(configuration: configuration))
    }

    override func setUp() {
        StubProtocol.status = 200
        StubProtocol.body = Data()
        StubProtocol.requests = 0
    }

    private let local = URLRequest(url: URL(string: "http://127.0.0.1:9/alerts")!)

    func testABodyWithStatus200IsReturned() async throws {
        StubProtocol.body = Data("{\"features\":[]}".utf8)
        let data = try await fetcher().data(for: local)
        XCTAssertEqual(data, StubProtocol.body)
    }

    /// The NWS answers an overload with 503 and a JSON problem document;
    /// reading that as alerts would draw nothing and call it current.
    func testAnHTTPErrorIsAFailureNotData() async {
        StubProtocol.status = 503
        StubProtocol.body = Data("{\"title\":\"Service Unavailable\"}".utf8)
        do {
            _ = try await fetcher().data(for: local)
            XCTFail("a 503 must not come back as data")
        } catch {
            XCTAssertEqual(error as? HazardFetchError, .status(503))
        }
    }

    /// Under XCTest nothing goes past loopback, so a real feed address is
    /// refused before any request is made.
    func testATestRunNeverReachesTheInternet() async {
        do {
            _ = try await fetcher().data(for: NWSAlertFeed.alertsRequest(
                near: GreatCircle.Point(latitude: 39.6, longitude: -104.7)))
            XCTFail("refused under XCTest")
        } catch {
            XCTAssertEqual(error as? HazardFetchError, .notAllowed("api.weather.gov"))
            XCTAssertEqual(StubProtocol.requests, 0)
        }
    }
}
