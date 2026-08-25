//
//  NodeProfileTests.swift
//  AXTermTests
//
//  A callsign appears in a dozen places and each used to show the fragment it
//  happened to hold. NodeProfile assembles the fragments once; these pin the
//  assembly rules, because "what do we know about this station" is a question
//  with a wrong answer.
//

import XCTest
@testable import AXTerm

final class NodeProfileTests: XCTestCase {

    private let denver = GreatCircle.Point(latitude: 39.74, longitude: -104.99)

    private func heard(_ callsign: String,
                       count: Int = 5,
                       position: GreatCircle.Point? = nil,
                       confidence: HeardStationMap.PositionConfidence = .gridSquare,
                       isNodeAlias: Bool = false,
                       name: String? = nil,
                       via: [String] = []) -> HeardStationMap.Entry {
        HeardStationMap.Entry(
            callsign: callsign, heardCount: count,
            lastHeard: Date(timeIntervalSince1970: 1_700_000_000),
            lastVia: via, position: position, positionSource: position == nil ? nil : "test",
            confidence: confidence, gridSquare: "DM79", name: name,
            locality: nil, isNodeAlias: isNodeAlias)
    }

    // MARK: - Identity

    func testCallsignIsSplitIntoBaseAndSSID() {
        let profile = NodeProfile.make(callsign: "k0nts-10")
        XCTAssertEqual(profile.callsign, "K0NTS-10")
        XCTAssertEqual(profile.baseCallsign, "K0NTS")
        XCTAssertEqual(profile.ssid, 10)
    }

    func testABareCallsignHasNoSSID() {
        let profile = NodeProfile.make(callsign: "W0TX")
        XCTAssertEqual(profile.baseCallsign, "W0TX")
        XCTAssertNil(profile.ssid, "W0TX and W0TX-0 are written differently for a reason")
    }

    func testTappingAnAliasResolvesToTheStationBehindIt() {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "DRLNOD", callsign: "KE0NCQ-7", service: "node"),
                       at: Date())

        let profile = NodeProfile.make(callsign: "DRLNOD", aliasDirectory: aliases)

        XCTAssertEqual(profile.callsign, "KE0NCQ-7")
        // The page has to say which name led here, or an alias tap silently
        // becomes a different callsign.
        XCTAssertEqual(profile.resolvedFromAlias, "DRLNOD")
    }

    func testAStationWithAnAliasAdvertisesIt() {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "DRLNOD", callsign: "KE0NCQ-7", service: "node"),
                       at: Date())

        let profile = NodeProfile.make(callsign: "KE0NCQ-7", aliasDirectory: aliases)

        XCTAssertEqual(profile.alias, "DRLNOD")
        XCTAssertNil(profile.resolvedFromAlias, "they tapped the callsign, not the alias")
    }

    // MARK: - Roles are evidence

    func testOurOwnCallsignIsNamedAsSuch() {
        let profile = NodeProfile.make(callsign: "K0EPI-7", localCallsign: "k0epi-7")
        XCTAssertTrue(profile.roles.contains(.ourStation))
    }

    func testANeighbourIsMeasuredButNotLabelledANode() {
        let profile = NodeProfile.make(callsign: "AB0VZ", neighbourQuality: 80)
        // The neighbour table is built by watching traffic, so membership
        // means "nearby and audible", not "runs NET/ROM". Claiming otherwise
        // put the label on ordinary stations.
        XCTAssertFalse(profile.roles.contains(.netromNode))
        XCTAssertEqual(profile.netrom?.neighbourQuality, 80,
                       "the measurement is real and stays")
    }

    func testOnlyADeclarationEarnsTheNodeLabel() {
        let declared = NodeProfile.make(callsign: "AB0VZ", neighbourQuality: 80,
                                        netRomDeclaration: .nodesBroadcast)
        XCTAssertTrue(declared.roles.contains(.netromNode))
    }

    func testACallsignSeenInAViaPathIsADigipeater() {
        let profile = NodeProfile.make(callsign: "DRLNOD",
                                       digipeaterCallsigns: ["DRLNOD", "HORSE"])
        XCTAssertTrue(profile.roles.contains(.digipeater))
    }

    func testAStationWeHaveExchangedMailWithIsAGateway() {
        let quality = WinlinkLinkQuality(callsign: "W0ARP-10", frequencyHz: nil)
        let profile = NodeProfile.make(callsign: "W0ARP-10", winlink: quality)
        XCTAssertTrue(profile.roles.contains(.winlinkGateway))
    }

    func testAPlainHeardStationClaimsNoRoles() {
        let profile = NodeProfile.make(callsign: "KD0SSP", heard: heard("KD0SSP"))
        XCTAssertTrue(profile.roles.isEmpty,
                      "roles are earned by evidence, not assumed")
    }

    func testEveryRoleCanExplainItself() {
        for role in NodeProfile.Role.allCases {
            XCTAssertFalse(role.evidence.isEmpty,
                           "\(role) claims something about a station without saying why")
            XCTAssertFalse(role.label.isEmpty)
        }
    }

    // MARK: - Position

    func testDistanceAndBearingAreComputedFromTheOperator() {
        let boulder = GreatCircle.Point(latitude: 40.015, longitude: -105.27)
        let profile = NodeProfile.make(
            callsign: "W0TX",
            heard: heard("W0TX", position: boulder),
            observer: denver)

        let placement = try? XCTUnwrap(profile.placement)
        XCTAssertNotNil(placement?.distanceKilometres)
        // Denver to Boulder is roughly 40 km; the exact figure is the
        // great-circle code's business, not this one's.
        XCTAssertEqual(placement?.distanceKilometres ?? 0, 40, accuracy: 8)
        XCTAssertNotNil(placement?.bearingDegrees)
    }

    func testNoObserverMeansNoDistanceRatherThanAWrongOne() {
        let profile = NodeProfile.make(
            callsign: "W0TX", heard: heard("W0TX", position: denver), observer: nil)
        XCTAssertNotNil(profile.placement)
        XCTAssertNil(profile.placement?.distanceKilometres)
    }

    func testConfidenceSurvivesIntoTheProfile() {
        let profile = NodeProfile.make(
            callsign: "DRLNOD",
            heard: heard("DRLNOD", position: denver, confidence: .inferredFromOperator))
        // A node placed at its operator's house is a lead, not a location,
        // and the page says so — but only if the confidence reaches it.
        XCTAssertEqual(profile.placement?.confidence, .inferredFromOperator)
    }

    func testAnUnplacedStationHasNoPlacement() {
        let profile = NodeProfile.make(callsign: "KB5YZB-7", heard: heard("KB5YZB-7"))
        XCTAssertNil(profile.placement)
        XCTAssertFalse(profile.isPlaced)
    }

    // MARK: - Directory versus heard data

    func testDirectoryNameWinsOverTheHeardEntrysCopy() {
        var record = CallsignRecord(callsign: "W0TX", source: "HamDB", fetchedAt: Date())
        record.name = "From directory"
        let profile = NodeProfile.make(
            callsign: "W0TX",
            heard: heard("W0TX", name: "Stale copy"),
            directory: record)
        XCTAssertEqual(profile.name, "From directory")
        XCTAssertEqual(profile.directorySource, "HamDB")
    }

    func testHeardNameIsUsedWhenNoDirectoryAnswered() {
        let profile = NodeProfile.make(
            callsign: "W0TX", heard: heard("W0TX", name: "Known already"))
        XCTAssertEqual(profile.name, "Known already")
    }

    // MARK: - Activity and routing

    func testActivityCarriesWhatWasActuallyHeard() {
        let profile = NodeProfile.make(
            callsign: "KB5YZB-7",
            heard: heard("KB5YZB-7", count: 12, via: ["DRLNOD", "FNKTWN"]))
        XCTAssertEqual(profile.activity?.heardCount, 12)
        XCTAssertEqual(profile.activity?.lastVia, ["DRLNOD", "FNKTWN"])
    }

    func testRoutesThroughANodeAreListedSorted() {
        let profile = NodeProfile.make(
            callsign: "DRLNOD", routesVia: ["KB5YZB-7", "AB0VZ", "KN6VV-1"])
        XCTAssertEqual(profile.netrom?.routesVia, ["AB0VZ", "KB5YZB-7", "KN6VV-1"])
    }

    func testNoRoutingFactsMeansNoNetRomSectionAtAll() {
        let profile = NodeProfile.make(callsign: "W0TX", heard: heard("W0TX"))
        XCTAssertNil(profile.netrom, "an empty section is worse than an absent one")
    }

    // MARK: - The empty case

    func testACallsignWithNothingKnownIsMarkedBare() {
        let profile = NodeProfile.make(callsign: "N0CALL-1")
        XCTAssertTrue(profile.isBare)
    }

    func testAnyKnownFactStopsItBeingBare() {
        let profile = NodeProfile.make(callsign: "N0CALL-1", heard: heard("N0CALL-1"))
        XCTAssertFalse(profile.isBare)
    }

    // MARK: - Subtitle

    func testSubtitlePrefersTheLicenseeAndPlace() {
        var record = CallsignRecord(callsign: "W0TX", source: "HamDB", fetchedAt: Date())
        record.name = "Jane Doe"
        record.locality = "Boulder"
        let profile = NodeProfile.make(callsign: "W0TX", directory: record)
        XCTAssertEqual(profile.subtitle, "Jane Doe \u{00B7} Boulder")
    }

    func testSubtitleFallsBackToTheAliasWhenNothingElseIsKnown() {
        var aliases = NodeAliasDirectory()
        aliases.record(.init(alias: "DRLNOD", callsign: "KE0NCQ-7", service: "node"),
                       at: Date())
        let profile = NodeProfile.make(callsign: "KE0NCQ-7", aliasDirectory: aliases)
        XCTAssertEqual(profile.subtitle, "Also announced as DRLNOD")
    }
}

// MARK: - Directed links and SSID siblings

extension NodeProfileTests {

    private func link(from: String, to: String, quality: Int = 100,
                      df: Double? = nil, dr: Double? = nil,
                      duplicates: Int = 0, fromUs: Bool) -> NodeProfile.DirectedLink {
        NodeProfile.DirectedLink(
            from: from, to: to, quality: quality, df: df, dr: dr,
            duplicates: duplicates,
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            isFromUs: fromUs)
    }

    func testOurDirectionIsListedFirst() {
        let profile = NodeProfile.make(
            callsign: "W0ARP-10",
            links: [link(from: "W0ARP-10", to: "K0EPI-7", fromUs: false),
                    link(from: "K0EPI-7", to: "W0ARP-10", fromUs: true)])
        // "Can they hear me" is the direction an operator can act on.
        XCTAssertTrue(profile.links.first?.isFromUs ?? false)
        XCTAssertNotNil(profile.outboundLink)
        XCTAssertNotNil(profile.inboundLink)
    }

    func testETXFollowsTheSpecFormula() {
        let l = link(from: "K0EPI-7", to: "W0ARP-10", df: 0.5, dr: 0.5, fromUs: true)
        // 1 / (0.5 × 0.5) = 4
        XCTAssertEqual(try XCTUnwrap(l.etx), 4.0, accuracy: 0.001)
    }

    func testETXIsClampedAtTwenty() {
        // Floors of 0.05 give 1/(0.05×0.05) = 400, which the clamp cuts to 20.
        let l = link(from: "K0EPI-7", to: "W0ARP-10", df: 0.0, dr: 0.0, fromUs: true)
        XCTAssertEqual(try XCTUnwrap(l.etx), 20.0, accuracy: 0.001)
    }

    func testETXNeverDropsBelowOne() {
        let l = link(from: "K0EPI-7", to: "W0ARP-10", df: 1.0, dr: 1.0, fromUs: true)
        XCTAssertEqual(try XCTUnwrap(l.etx), 1.0, accuracy: 0.001)
    }

    func testETXIsAbsentWithoutBothProbabilities() {
        let l = link(from: "K0EPI-7", to: "W0ARP-10", df: 0.9, dr: nil, fromUs: true)
        XCTAssertNil(l.etx, "half a measurement is not a measurement")
    }

    func testAsymmetryIsPreservedRatherThanBlended() {
        let profile = NodeProfile.make(
            callsign: "W0ARP-10",
            links: [link(from: "K0EPI-7", to: "W0ARP-10", quality: 63, fromUs: true),
                    link(from: "W0ARP-10", to: "K0EPI-7", quality: 208, fromUs: false)])
        // One blended number would read as a mediocre path and send the
        // operator looking at the wrong end of it.
        XCTAssertEqual(profile.outboundLink?.quality, 63)
        XCTAssertEqual(profile.inboundLink?.quality, 208)
    }

    func testSiblingsAreSortedBySSIDAndExcludeTheSubject() {
        let profile = NodeProfile.make(
            callsign: "K0NTS-10",
            siblings: [
                .init(callsign: "K0NTS-10", ssid: 10, heardCount: 1, lastHeard: nil, roles: []),
                .init(callsign: "K0NTS-7", ssid: 7, heardCount: 2, lastHeard: nil, roles: []),
                .init(callsign: "K0NTS-1", ssid: 1, heardCount: 3, lastHeard: nil, roles: []),
            ])
        XCTAssertEqual(profile.siblings.map(\.callsign), ["K0NTS-1", "K0NTS-7"],
                       "the station being viewed is not its own sibling")
    }

    func testLinksOrSiblingsAloneStopAProfileBeingBare() {
        let withLink = NodeProfile.make(
            callsign: "W0ARP-10",
            links: [link(from: "K0EPI-7", to: "W0ARP-10", fromUs: true)])
        XCTAssertFalse(withLink.isBare)
    }
}
