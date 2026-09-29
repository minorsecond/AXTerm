import XCTest
@testable import AXTerm

final class CallsignQueryTests: XCTestCase {

    /// Directories index licences, and a licence has no SSID. Querying
    /// "W0ARP-10" returns nothing, which looks exactly like "no such
    /// station" — so this is the difference between the feature working
    /// and appearing to have no data.
    func testSSIDIsStrippedBeforeLookup() {
        XCTAssertEqual(CallsignQuery.normalize("W0ARP-10"), "W0ARP")
        XCTAssertEqual(CallsignQuery.normalize("k0epi-7"), "K0EPI")
        XCTAssertEqual(CallsignQuery.normalize("  n0hi-10  "), "N0HI")
    }

    func testBareCallsignsAreUnchangedApartFromCase() {
        XCTAssertEqual(CallsignQuery.normalize("kd0ssp"), "KD0SSP")
    }

    /// Tactical aliases are destinations, not licensees. Sending them to
    /// a directory wastes a round trip and leaks traffic patterns.
    func testTacticalAliasesAreNotPlausibleCallsigns() {
        for alias in ["MAIL", "BEACON", "ID", "QST", "NODE"] {
            XCTAssertFalse(CallsignQuery.isPlausible(alias), alias)
        }
    }

    func testRealCallsignsArePlausible() {
        for call in ["K0EPI", "W0ARP-10", "N0HI-10", "KB5YZB-7", "2E0ABC"] {
            XCTAssertTrue(CallsignQuery.isPlausible(call), call)
        }
    }

    func testGarbageIsRejected() {
        XCTAssertFalse(CallsignQuery.isPlausible(""))
        XCTAssertFalse(CallsignQuery.isPlausible("K"))
        XCTAssertFalse(CallsignQuery.isPlausible("VERYLONGCALLSIGN"))
        XCTAssertFalse(CallsignQuery.isPlausible("K0EPI/P"), "slashes are not handled")
    }
}

final class HamDBDirectoryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// The **versioned** path is required — the unversioned one answers
    /// 302 with an empty body (verified 2026-08-24).
    func testURLUsesTheVersionedPathAndBaseCallsign() throws {
        let directory = HamDBDirectory(appName: "AXTerm")
        let url = try XCTUnwrap(directory.url(for: "W0ARP-10"))
        XCTAssertEqual(url.absoluteString, "https://api.hamdb.org/v1/W0ARP/json/AXTerm")
    }

    /// Shape captured live on 2026-08-24; personal details replaced.
    private let hit = Data("""
    {"hamdb":{"version":"1","callsign":{
      "call":"W0ARP","class":"E","expires":"07/25/2035","status":"A",
      "grid":"DM79ql","lat":"39.4918279","lon":"-104.6398437",
      "fname":"ALEX","mi":"R","name":"EXAMPLE","suffix":"",
      "addr1":"1 Example St","addr2":"PARKER","state":"CO",
      "zip":"80134","country":"United States"},
      "messages":{"status":"OK"}}}
    """.utf8)

    /// The real miss payload — HTTP 200, every field the sentinel.
    private let miss = Data("""
    {"hamdb":{"version":"1","callsign":{
      "call":"NOT_FOUND","class":"NOT_FOUND","expires":"NOT_FOUND",
      "status":"NOT_FOUND","grid":"NOT_FOUND","lat":"NOT_FOUND",
      "lon":"NOT_FOUND","fname":"NOT_FOUND","mi":"NOT_FOUND",
      "name":"NOT_FOUND","suffix":"NOT_FOUND","addr1":"NOT_FOUND",
      "addr2":"NOT_FOUND","state":"NOT_FOUND","zip":"NOT_FOUND",
      "country":"NOT_FOUND"},
      "messages":{"status":"NOT_FOUND"}}}
    """.utf8)

    func testDecodesAKnownCallsign() throws {
        let record = try XCTUnwrap(HamDBDirectory.decode(hit, now: now))
        XCTAssertEqual(record.callsign, "W0ARP")
        XCTAssertEqual(record.gridSquare, "DM79ql")
        XCTAssertEqual(record.latitude ?? 0, 39.4918279, accuracy: 0.000001)
        XCTAssertEqual(record.longitude ?? 0, -104.6398437, accuracy: 0.000001)
        XCTAssertEqual(record.state, "CO")
        XCTAssertEqual(record.locality, "Parker")
        XCTAssertEqual(record.source, "HamDB")
    }

    /// hamdb prints names in two fields, inconsistently cased.
    func testNameIsJoinedAndNormalised() throws {
        let record = try XCTUnwrap(HamDBDirectory.decode(hit, now: now))
        XCTAssertEqual(record.name, "Alex Example")
    }

    /// The trap: a miss is HTTP 200 with sentinels everywhere. Parsed
    /// naively this yields a station called NOT_FOUND in grid NOT_FOUND.
    func testTheNotFoundSentinelIsAMissNotARecord() {
        XCTAssertNil(HamDBDirectory.decode(miss, now: now))
    }

    /// Even without the status field, per-field sentinels must not leak
    /// into a record.
    func testSentinelFieldsAreNeverStoredAsValues() {
        let partial = Data("""
        {"hamdb":{"version":"1","callsign":{
          "call":"K0EPI","grid":"NOT_FOUND","lat":"NOT_FOUND","lon":"NOT_FOUND",
          "fname":"Robert","name":"Wardrup","state":"CO"},
          "messages":{"status":"OK"}}}
        """.utf8)
        guard let record = HamDBDirectory.decode(partial, now: now) else {
            return XCTFail("a partial record is still a record")
        }
        XCTAssertNil(record.gridSquare)
        XCTAssertNil(record.latitude)
        XCTAssertEqual(record.state, "CO")
    }

    func testGarbageBodyIsAMissNotACrash() {
        XCTAssertNil(HamDBDirectory.decode(Data("not json".utf8), now: now))
        XCTAssertNil(HamDBDirectory.decode(Data(), now: now))
        XCTAssertNil(HamDBDirectory.decode(Data("{}".utf8), now: now))
    }

    /// Coordinates come from lat/lon when present, and fall back to the
    /// grid square when only that is known.
    func testPositionPrefersCoordinatesAndFallsBackToGrid() throws {
        let record = try XCTUnwrap(HamDBDirectory.decode(hit, now: now))
        XCTAssertEqual(record.position?.latitude ?? 0, 39.4918279, accuracy: 0.000001)

        let gridOnly = CallsignRecord(
            callsign: "K0EPI", gridSquare: "DM79po",
            source: "test", fetchedAt: now)
        let position = try XCTUnwrap(gridOnly.position)
        XCTAssertEqual(position.latitude, 39.6, accuracy: 0.1)
    }
}

final class CallsignDirectoryChainTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fake: CallsignDirectory {
        var sourceName: String
        var requiresNetwork: Bool
        var record: CallsignRecord?
        var error: Error?
        func lookup(_ callsign: String) async throws -> CallsignRecord? {
            if let error { throw error }
            return record
        }
    }

    private struct Boom: Error {}

    private func record(_ source: String) -> CallsignRecord {
        CallsignRecord(callsign: "W0ARP", gridSquare: "DM79ql",
                       source: source, fetchedAt: now)
    }

    func testFirstAnswerWins() async throws {
        let chain = CallsignDirectoryChain([
            Fake(sourceName: "local", requiresNetwork: false, record: record("local")),
            Fake(sourceName: "remote", requiresNetwork: true, record: record("remote")),
        ])
        let found = try await chain.lookup("W0ARP-10")
        XCTAssertEqual(found?.source, "local")
    }

    /// One service being down must not mask another that works.
    func testAThrowingSourceDoesNotStopTheChain() async throws {
        let chain = CallsignDirectoryChain([
            Fake(sourceName: "broken", requiresNetwork: true, record: nil, error: Boom()),
            Fake(sourceName: "working", requiresNetwork: true, record: record("working")),
        ])
        let found = try await chain.lookup("W0ARP")
        XCTAssertEqual(found?.source, "working")
    }

    /// If nothing answered and something failed, the caller hears about
    /// it — silence would look like "no such station".
    func testAnErrorSurfacesOnlyWhenNothingAnswered() async {
        let chain = CallsignDirectoryChain([
            Fake(sourceName: "broken", requiresNetwork: true, record: nil, error: Boom()),
        ])
        do {
            _ = try await chain.lookup("W0ARP")
            XCTFail("expected the error to surface")
        } catch {
            // expected
        }
    }

    /// The grid-down posture: skip every network source without even
    /// attempting it.
    func testNetworkSourcesAreSkippedWhenNotAllowed() async throws {
        let chain = CallsignDirectoryChain([
            Fake(sourceName: "remote", requiresNetwork: true, record: record("remote")),
            Fake(sourceName: "local", requiresNetwork: false, record: record("local")),
        ], allowsNetwork: false)
        let found = try await chain.lookup("W0ARP")
        XCTAssertEqual(found?.source, "local")
    }

    func testOfflineChainWithNoLocalSourceReturnsNothingRatherThanThrowing() async throws {
        let chain = CallsignDirectoryChain([
            Fake(sourceName: "remote", requiresNetwork: true, record: nil, error: Boom()),
        ], allowsNetwork: false)
        let found = try await chain.lookup("W0ARP")
        XCTAssertNil(found)
    }

    /// An implausible callsign never reaches a source at all.
    func testImplausibleCallsignsNeverHitASource() async throws {
        let chain = CallsignDirectoryChain([
            Fake(sourceName: "remote", requiresNetwork: true, record: record("remote")),
        ])
        let mail = try await chain.lookup("MAIL")
        XCTAssertNil(mail)
        let beacon = try await chain.lookup("BEACON")
        XCTAssertNil(beacon)
    }

    /// An empty record is not an answer; the chain keeps looking.
    func testEmptyRecordsAreSkipped() async throws {
        let empty = CallsignRecord(callsign: "W0ARP", source: "empty", fetchedAt: now)
        let chain = CallsignDirectoryChain([
            Fake(sourceName: "empty", requiresNetwork: false, record: empty),
            Fake(sourceName: "real", requiresNetwork: false, record: record("real")),
        ])
        let found = try await chain.lookup("W0ARP")
        XCTAssertEqual(found?.source, "real")
    }
}
