//
//  CoverageEstimateTests.swift
//  AXTermTests
//
//  Coverage is who answered us, not who we can hear — a hilltop node is
//  heard far beyond a home station's own reach. The rings are measured
//  from stations that demonstrably decoded this station's transmissions.
//

import XCTest
@testable import AXTerm

final class CoverageEstimateTests: XCTestCase {

    private let observer = GreatCircle.Point(latitude: 39.0, longitude: -105.0)

    private func path(from: String, to: String, via: [String] = [],
                      evidence: NetworkPath.Evidence = .sessionEstablished,
                      lastSeen: Date = Date()) -> NetworkPath {
        NetworkPath(from: from, to: to, via: via, evidence: evidence,
                    observations: 1, firstSeen: lastSeen, lastSeen: lastSeen,
                    unansweredAttempts: 0)
    }

    /// Roughly north of the observer by a chosen number of kilometres.
    private func point(kmNorth: Double) -> GreatCircle.Point {
        GreatCircle.Point(latitude: observer.latitude + kmNorth / 111.32,
                          longitude: observer.longitude)
    }

    func testRingsComeFromDirectAnswers() {
        let paths = [
            path(from: "DRLNOD", to: "K0EPI-7"),   // 10 km, answered
            path(from: "K0EPI-7", to: "AB0VZ"),    // 30 km, answered
            path(from: "K0EPI-7", to: "KB5YZB-7")  // 50 km, answered
        ]
        let positions = [
            "DRLNOD": point(kmNorth: 10),
            "AB0VZ": point(kmNorth: 30),
            "KB5YZB-7": point(kmNorth: 50)
        ]
        let ring = CoverageEstimate.ring(paths: paths, ownAddresses: ["K0EPI-7"],
                                         positions: positions, observer: observer)
        XCTAssertEqual(ring?.stationCount, 3)
        XCTAssertEqual(ring?.farthestCallsign, "KB5YZB-7")
        XCTAssertEqual(ring!.reachKm, 50, accuracy: 1)
        XCTAssertEqual(ring!.typicalKm, 30, accuracy: 1,
                       "median of 10, 30, 50")
        XCTAssertTrue(ring!.summary.contains("KB5YZB-7"))
    }

    /// The bug this guards: our own transmissions come back through the
    /// receive path, so a station we called and never reached still has a
    /// direct path to us. It is not inside our footprint, and because the
    /// outer ring is the farthest answerer, counting it would have let one
    /// unanswered call to a distant node set the entire reach figure.
    func testAStationWeCalledButNeverReachedDoesNotCount() {
        let paths = [
            path(from: "DRLNOD", to: "K0EPI-7"),                          // 10 km, answered
            path(from: "K0EPI-7", to: "W0ARP-10", evidence: .heardDirect) // 90 km, silent
        ]
        let positions = [
            "DRLNOD": point(kmNorth: 10),
            "W0ARP-10": point(kmNorth: 90)
        ]
        let ring = CoverageEstimate.ring(paths: paths, ownAddresses: ["K0EPI-7"],
                                         positions: positions, observer: observer)
        XCTAssertEqual(ring?.stationCount, 1)
        XCTAssertEqual(ring?.farthestCallsign, "DRLNOD")
        XCTAssertEqual(ring!.reachKm, 10, accuracy: 1,
                       "the unanswered 90 km call must not set the reach")
    }

    /// Nothing has answered, so there is no measurement to draw.
    func testNoAnswersMeansNoRingAtAll() {
        let paths = [
            path(from: "K0EPI-7", to: "W0ARP-10", evidence: .heardDirect),
            path(from: "K0EPI-7", to: "AB0VZ", evidence: .heardDirect)
        ]
        XCTAssertNil(CoverageEstimate.ring(
            paths: paths, ownAddresses: ["K0EPI-7"],
            positions: ["W0ARP-10": point(kmNorth: 90), "AB0VZ": point(kmNorth: 30)],
            observer: observer))
    }

    /// A digipeated answer proves the digipeater's coverage, not ours.
    func testDigipeatedPathsDoNotCount() {
        let paths = [path(from: "K0NTS-1", to: "K0EPI-7", via: ["W2CRS-7"])]
        XCTAssertNil(CoverageEstimate.ring(
            paths: paths, ownAddresses: ["K0EPI-7"],
            positions: ["K0NTS-1": point(kmNorth: 80)], observer: observer))
    }

    /// An inferred path was never actually travelled.
    func testTransitivePathsDoNotCount() {
        let paths = [path(from: "K0EPI-7", to: "COSCO", evidence: .transitive)]
        XCTAssertNil(CoverageEstimate.ring(
            paths: paths, ownAddresses: ["K0EPI-7"],
            positions: ["COSCO": point(kmNorth: 60)], observer: observer))
    }

    /// K0EPI-6 is DRLNOD's transmitter borrowing our callsign — its links
    /// measure DRLNOD's coverage. Full-address matching keeps it out.
    func testABorrowedRelayLegIsNotOurTransmitter() {
        let paths = [path(from: "K0EPI-6", to: "KB5YZB-7")]
        XCTAssertNil(CoverageEstimate.ring(
            paths: paths, ownAddresses: ["K0EPI-7"],
            positions: ["KB5YZB-7": point(kmNorth: 40)], observer: observer))
    }

    func testStaleEvidenceExpires() {
        let old = Date().addingTimeInterval(-CoverageEstimate.evidenceWindow - 3600)
        let paths = [path(from: "DRLNOD", to: "K0EPI-7", lastSeen: old)]
        XCTAssertNil(CoverageEstimate.ring(
            paths: paths, ownAddresses: ["K0EPI-7"],
            positions: ["DRLNOD": point(kmNorth: 10)], observer: observer))
    }

    func testAnUnplacedAnswererContributesNothing() {
        let paths = [path(from: "DRLNOD", to: "K0EPI-7")]
        XCTAssertNil(CoverageEstimate.ring(
            paths: paths, ownAddresses: ["K0EPI-7"],
            positions: [:], observer: observer))
    }

    /// One station, one distance: both rings collapse onto it honestly.
    func testASingleAnswererMakesBothRings() {
        let paths = [path(from: "DRLNOD", to: "K0EPI-7")]
        let ring = CoverageEstimate.ring(
            paths: paths, ownAddresses: ["K0EPI-7"],
            positions: ["DRLNOD": point(kmNorth: 10)], observer: observer)
        XCTAssertEqual(ring?.stationCount, 1)
        XCTAssertEqual(ring!.typicalKm, ring!.reachKm, accuracy: 0.001)
    }

    // MARK: - APRS: who put our frames back on the air

    private func here() -> GreatCircle.Point {
        GreatCircle.Point(latitude: 39.6125, longitude: -104.7328)
    }

    /// A digipeater that repeated our beacon decoded our beacon. That is the
    /// same standard the connected-mode ring applies to a UA, and it is the
    /// only evidence an APRS station collects without going looking for it.
    func testADigipeaterThatRepeatedUsIsAMeasuredPoint() {
        let now = Date()
        let ring = CoverageEstimate.digipeatRing(
            repeaters: ["AD1CT": now, "WQ8M-9": now],
            positions: [
                "AD1CT": GreatCircle.Point(latitude: 39.6227, longitude: -104.7726),
                "WQ8M-9": GreatCircle.Point(latitude: 39.5580, longitude: -104.7942),
            ],
            observer: here(), now: now)

        XCTAssertEqual(ring?.stationCount, 2)
        XCTAssertEqual(ring?.evidence, .digipeated)
        XCTAssertEqual(ring?.farthestCallsign, "WQ8M-9")
    }

    /// Kept apart from the connected-mode ring on purpose. One answers "who
    /// will talk to me", the other "where does my beacon land", and a single
    /// figure built from both answers neither.
    func testTheTwoKindsOfRingSayDifferentThings() throws {
        let now = Date()
        let ring = CoverageEstimate.digipeatRing(
            repeaters: ["AD1CT": now],
            positions: ["AD1CT": GreatCircle.Point(latitude: 39.6227, longitude: -104.7726)],
            observer: here(), now: now)

        let summary = try XCTUnwrap(ring?.summary(inMiles: true))
        XCTAssertTrue(summary.contains("digipeater"), summary)
        XCTAssertTrue(summary.contains("repeating a frame proves"), summary)
        XCTAssertFalse(summary.contains("UA, DM or FRMR"),
                       "that is the other ring's evidence, and saying so here would be a lie")
    }

    /// Propagation shifts with seasons and antennas with ladders. A repeat
    /// from last month proves last month.
    func testStaleRepeatsDoNotCount() {
        let now = Date()
        let old = now.addingTimeInterval(-CoverageEstimate.evidenceWindow - 60)
        XCTAssertNil(CoverageEstimate.digipeatRing(
            repeaters: ["AD1CT": old],
            positions: ["AD1CT": GreatCircle.Point(latitude: 39.6227, longitude: -104.7726)],
            observer: here(), now: now))
    }

    /// A repeater we cannot place tells us nothing about distance, so it is
    /// not a measurement. Better no ring than a ring drawn round the ones we
    /// happen to have coordinates for and claimed as all of them.
    func testARepeaterWithNoKnownPositionIsNotCounted() {
        let now = Date()
        let ring = CoverageEstimate.digipeatRing(
            repeaters: ["AD1CT": now, "NOWHERE": now],
            positions: ["AD1CT": GreatCircle.Point(latitude: 39.6227, longitude: -104.7726)],
            observer: here(), now: now)
        XCTAssertEqual(ring?.stationCount, 1)
    }

    func testNothingHasRepeatedUsYet() {
        XCTAssertNil(CoverageEstimate.digipeatRing(
            repeaters: [:], positions: [:], observer: here()))
    }

    /// Callsigns arrive from the air in whatever case the sender used.
    func testCallsignsAreMatchedWithoutCaringAboutCase() {
        let now = Date()
        let ring = CoverageEstimate.digipeatRing(
            repeaters: [" ad1ct ": now],
            positions: ["AD1CT": GreatCircle.Point(latitude: 39.6227, longitude: -104.7726)],
            observer: here(), now: now)
        XCTAssertEqual(ring?.stationCount, 1)
        XCTAssertEqual(ring?.farthestCallsign, "AD1CT")
    }
}
