import XCTest
@testable import AXTerm

/// The breaker between the map's trickle lookups and hamdb.org: a 429 or
/// outage must stop the whole pass, not be recorded as 500 misses.
@MainActor
final class CallsignLookupThrottleTests: XCTestCase {

    /// A directory that throws until told otherwise, counting calls.
    final class FlakyDirectory: CallsignDirectory, @unchecked Sendable {
        let sourceName = "Flaky"
        let requiresNetwork = true
        var callCount = 0
        var failing = true
        func lookup(_ callsign: String) async throws -> CallsignRecord? {
            callCount += 1
            if failing { throw CallsignDirectoryError.serverUnavailable(status: 429) }
            return CallsignRecord(
                callsign: callsign, name: nil, gridSquare: "DM79",
                latitude: 39.7, longitude: -104.9, locality: nil, state: nil,
                country: nil, licenseClass: nil, expires: nil,
                source: "Flaky", fetchedAt: Date())
        }
    }

    func testAThrottleOpensTheBreakerAndStopsTheBulkPass() async {
        let remote = FlakyDirectory()
        let service = CallsignLookupService(
            store: nil, remote: remote, isNetworkEnabled: true)

        await service.resolveAll(["W9OTR", "N0ABC", "K5XYZ"])

        XCTAssertEqual(remote.callCount, 1,
                       "the first refusal must silence the rest of the pass")
        XCTAssertTrue(service.isCoolingDown)

        _ = await service.resolve("W1DEF")
        XCTAssertEqual(remote.callCount, 1,
                       "individual lookups honor the breaker too")
    }

    func testAThrottledCallsignIsNotBurnedAsAMiss() async {
        let remote = FlakyDirectory()
        let service = CallsignLookupService(
            store: nil, remote: remote, isNetworkEnabled: true)
        service.cooldownSeconds = 0 // breaker closes immediately

        _ = await service.resolve("W9OTR")
        XCTAssertNil(service.cached("W9OTR"))

        remote.failing = false
        let record = await service.resolve("W9OTR")
        XCTAssertEqual(record?.gridSquare, "DM79",
                       "a throttle must not consume the one attempt per launch")
    }

    /// A quiet resolve must not touch the @Published dictionary — that
    /// publish is what re-rendered the app per record and froze it —
    /// while still being visible through cached() so nothing re-fetches.
    func testQuietResolvesStayStagedUntilFlushed() async {
        let remote = FlakyDirectory()
        remote.failing = false
        let service = CallsignLookupService(
            store: nil, remote: remote, isNetworkEnabled: true)

        _ = await service.resolve("W9OTR", publishImmediately: false)
        XCTAssertTrue(service.records.isEmpty,
                      "nothing published until the batch flush")
        XCTAssertEqual(service.cached("W9OTR")?.gridSquare, "DM79",
                       "but the staged record still counts as known")

        service.flushStaged()
        XCTAssertEqual(service.records["W9OTR"]?.gridSquare, "DM79")
    }

    func testHamDBSurfacesServerRefusalsAsErrorsNotMisses() {
        // 429/5xx classification lives in lookup(); decode() itself must
        // stay a pure miss-vs-record function so an HTML error page (not
        // JSON) is also never mistaken for a station.
        XCTAssertNil(HamDBDirectory.decode(
            Data("<html>Too Many Requests</html>".utf8), now: Date()))
    }
}
