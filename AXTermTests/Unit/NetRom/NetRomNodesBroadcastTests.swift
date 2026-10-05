import XCTest
@testable import AXTerm

/// Originating NODES broadcasts.
///
/// The strongest test here is the round trip: what our encoder emits is
/// fed to `NetRomBroadcastParser` — the parser that has been reading
/// real BPQ and TheNET broadcasts off this station's air for months — and
/// must come back identical. If the two ever disagree, one of them is
/// wrong about the wire, and the parser has the field evidence.
final class NetRomNodesBroadcastTests: XCTestCase {

    private let localNode = AX25Address(call: "K0EPI", ssid: 7)
    /// COSCO is an *alias*; the station behind it is KE0GB-7 — exactly
    /// as the field capture read: "Connected to COSCO:KE0GB-7".
    private let coscoNode = AX25Address(call: "KE0GB", ssid: 7)
    private let drlnod = AX25Address(call: "DRLNOD", ssid: 0)

    /// Wrap a payload in the UI frame the parser expects.
    private func packet(from source: AX25Address, payload: Data) -> Packet {
        Packet(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            from: source,
            to: AX25Address(call: "NODES", ssid: 0),
            via: [],
            frameType: .ui,
            control: 0x03,
            pid: NetRomWire.pid,
            info: payload,
            rawAx25: Data(),
            kissEndpoint: nil,
            infoText: nil
        )
    }

    // MARK: - Alias field

    func testAliasIsSixBytesOfPlainASCII() {
        XCTAssertEqual(NetRomNodesBroadcast.encodeAlias("EPINOD"),
                       Array("EPINOD".utf8))
        XCTAssertEqual(NetRomNodesBroadcast.encodeAlias("EPI"),
                       Array("EPI   ".utf8), "space padded, not null padded")
        XCTAssertEqual(NetRomNodesBroadcast.encodeAlias("verylongalias"),
                       Array("VERYLO".utf8), "uppercased and truncated to six")
        XCTAssertEqual(NetRomNodesBroadcast.encodeAlias(""),
                       Array("      ".utf8))
    }

    func testAliasDropsNonASCIIRatherThanMangling() {
        let encoded = NetRomNodesBroadcast.encodeAlias("EP\u{00C9}I")
        XCTAssertEqual(encoded.count, 6)
        for byte in encoded {
            XCTAssertTrue(byte >= 0x20 && byte <= 0x7E, "byte \(byte) is not printable ASCII")
        }
    }

    // MARK: - Round trip through the real parser

    /// Smoke run 2026-10-03-1, issue 38: this station listed itself as its
    /// only entry. A receiver learns the sender from the frame's source and
    /// the header's alias, so with nothing to list the frame is the header
    /// alone, as classic NET/ROM nodes send it.
    func testWithoutForwardingTheBroadcastIsTheHeaderAlone() {
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: localNode, localAlias: "EPINOD",
            forwarding: false, routes: [])
        XCTAssertTrue(entries.isEmpty)
        let payloads = NetRomNodesBroadcast.encode(originAlias: "EPINOD", entries: entries)
        XCTAssertEqual(payloads, [Data([0xFF] + Array("EPINOD".utf8))])

        guard let parsed = NetRomBroadcastParser.parse(
            packet: packet(from: localNode, payload: payloads[0])) else {
            return XCTFail("our own broadcast must parse with our own parser")
        }
        XCTAssertTrue(parsed.entries.isEmpty)
        XCTAssertEqual(parsed.originAlias, "EPINOD")
        XCTAssertEqual(parsed.originCallsign, "K0EPI-7")
    }

    func testMultipleEntriesRoundTripWithCallsignsAndQualitiesIntact() {
        let routes = [
            NetRomNodesBroadcast.KnownRoute(
                destination: coscoNode, alias: "COSCO", nextHop: drlnod, quality: 120),
            NetRomNodesBroadcast.KnownRoute(
                destination: AX25Address(call: "KB5YZB", ssid: 7),
                alias: "YZBBPQ",
                nextHop: drlnod, quality: 16)
        ]
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: localNode, localAlias: "EPINOD",
            forwarding: true, routes: routes)
        let payloads = NetRomNodesBroadcast.encode(originAlias: "EPINOD", entries: entries)

        guard let parsed = NetRomBroadcastParser.parse(
            packet: packet(from: localNode, payload: payloads[0])) else {
            return XCTFail("broadcast should parse")
        }
        XCTAssertEqual(parsed.entries.map(\.destinationCallsign),
                       ["KE0GB-7", "KB5YZB-7"])
        XCTAssertEqual(parsed.entries.map(\.destinationAlias),
                       ["COSCO", "YZBBPQ"])
        XCTAssertEqual(parsed.entries.map(\.quality), [120, 16])
        XCTAssertEqual(parsed.originAlias, "EPINOD")
        // Every advertised destination names *us* as the way there — that
        // is what advertising means.
        XCTAssertEqual(Set(parsed.entries.map(\.bestNeighborCallsign)), ["K0EPI-7"])
    }

    func testSSIDsSurviveTheRoundTrip() {
        for ssid in 0...15 {
            let node = AX25Address(call: "W0ARP", ssid: ssid)
            let entries = NetRomNodesBroadcast.advertisement(
                localNode: localNode, localAlias: "TESTND", forwarding: true,
                routes: [NetRomNodesBroadcast.KnownRoute(destination: node, alias: "ARP",
                                                         nextHop: drlnod, quality: 100)])
            let payloads = NetRomNodesBroadcast.encode(originAlias: "TESTND", entries: entries)
            guard let parsed = NetRomBroadcastParser.parse(
                packet: packet(from: localNode, payload: payloads[0])) else {
                return XCTFail("ssid \(ssid) should parse")
            }
            XCTAssertEqual(parsed.entries[0].destinationCallsign, node.display)
        }
    }

    // MARK: - Framing

    func testEntriesAreSplitAcrossFramesAtTheClassicLimit() {
        let routes = (0..<25).map { index in
            NetRomNodesBroadcast.KnownRoute(
                destination: AX25Address(call: "N\(index % 10)ABC", ssid: index % 16),
                alias: "R\(index)",
                nextHop: drlnod,
                quality: UInt8(1 + index % 200))
        }
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: localNode, localAlias: "EPINOD", forwarding: true, routes: routes)
        let payloads = NetRomNodesBroadcast.encode(originAlias: "EPINOD", entries: entries)

        XCTAssertGreaterThan(payloads.count, 1, "more than 11 entries must span frames")
        for payload in payloads {
            let entryBytes = payload.count - 1 - NetRomNodesBroadcast.aliasLength
            XCTAssertEqual(entryBytes % NetRomNodesBroadcast.entryLength, 0,
                           "each frame holds whole entries")
            XCTAssertLessThanOrEqual(entryBytes / NetRomNodesBroadcast.entryLength,
                                     NetRomNodesBroadcast.maxEntriesPerFrame)
            XCTAssertLessThanOrEqual(payload.count, 256,
                                     "a frame must stay inside the NET/ROM packet size")
            XCTAssertNotNil(NetRomBroadcastParser.parse(
                packet: packet(from: localNode, payload: payload)),
                "every frame must parse on its own")
        }
    }

    func testNoEntriesIsOneHeaderOnlyFrame() {
        XCTAssertEqual(NetRomNodesBroadcast.encode(originAlias: "EPINOD", entries: []).map(\.count), [7],
                       "the header alone says this node exists")
    }

    // MARK: - What we are willing to claim

    func testWithoutForwardingNothingIsListed() {
        // The rule that keeps this station from becoming a black hole:
        // never advertise a destination we will not carry traffic to.
        let routes = [
            NetRomNodesBroadcast.KnownRoute(
                destination: coscoNode, alias: "COSCO", nextHop: drlnod, quality: 200)
        ]
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: localNode, localAlias: "EPINOD",
            forwarding: false, routes: routes)
        XCTAssertTrue(entries.isEmpty)
    }

    func testForwardingAdvertisesLearnedRoutes() {
        let routes = [
            NetRomNodesBroadcast.KnownRoute(
                destination: coscoNode, alias: "COSCO", nextHop: drlnod, quality: 200)
        ]
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: localNode, localAlias: "EPINOD",
            forwarding: true, routes: routes)
        XCTAssertEqual(entries.map(\.destination.display), ["KE0GB-7"])
    }

    func testSplitHorizonSuppressesARouteBackToItsOwnHop() {
        // Telling DRLNOD "reach DRLNOD through me" invites a loop.
        let routes = [
            NetRomNodesBroadcast.KnownRoute(
                destination: drlnod, alias: "DRLNOD", nextHop: drlnod, quality: 200)
        ]
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: localNode, localAlias: "EPINOD",
            forwarding: true, routes: routes)
        XCTAssertTrue(entries.isEmpty, "nothing survives: \(entries)")
    }

    func testZeroQualityRoutesAreNotAdvertised() {
        let routes = [
            NetRomNodesBroadcast.KnownRoute(
                destination: coscoNode, alias: "COSCO", nextHop: drlnod, quality: 0)
        ]
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: localNode, localAlias: "EPINOD",
            forwarding: true, routes: routes)
        XCTAssertTrue(entries.isEmpty, "an unusable route must not be offered to others")
    }

    func testDuplicateDestinationsAreAdvertisedOnce() {
        let routes = [
            NetRomNodesBroadcast.KnownRoute(
                destination: coscoNode, alias: "COSCO", nextHop: drlnod, quality: 200),
            NetRomNodesBroadcast.KnownRoute(
                destination: coscoNode, alias: "COSCO", nextHop: localNode, quality: 100)
        ]
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: localNode, localAlias: "EPINOD",
            forwarding: true, routes: routes)
        XCTAssertEqual(entries.map(\.destination.display), ["KE0GB-7"])
    }

    func testAliasShapedDestinationsAreResolvedBeforeAdvertising() {
        // EVANS is a tactical name; W0ARP-10 is the station. Advertising
        // it under the callsign is what a conforming parser can accept —
        // and the tactical name still rides the entry's alias field.
        let routes = [
            NetRomNodesBroadcast.KnownRoute(
                destination: AX25Address(call: "EVANS", ssid: 0), alias: "",
                nextHop: drlnod, quality: 61)
        ]
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: localNode, localAlias: "EPINOD",
            forwarding: true, routes: routes,
            callsignForAlias: { $0 == "EVANS" ? "W0ARP-10" : nil })

        XCTAssertEqual(entries.map(\.destination.display), ["W0ARP-10"])
        XCTAssertEqual(entries[0].alias, "EVANS", "the tactical name survives, in its own field")

        guard let parsed = NetRomBroadcastParser.parse(packet: packet(
            from: localNode,
            payload: NetRomNodesBroadcast.encode(originAlias: "EPINOD", entries: entries)[0]))
        else { return XCTFail("resolved broadcast should parse") }
        XCTAssertEqual(parsed.entries.map(\.destinationCallsign), ["W0ARP-10"])
        XCTAssertEqual(parsed.entries[0].destinationAlias, "EVANS")
    }

    func testSplitHorizonSurvivesResolution() {
        // Our route to DRLNOD is through DRLNOD. Whether the table stored
        // that as the alias or the callsign, it must not be advertised.
        let routes = [
            NetRomNodesBroadcast.KnownRoute(
                destination: AX25Address(call: "DRLNOD", ssid: 0), alias: "DRLNOD",
                nextHop: AX25Address(call: "KE0NCQ", ssid: 0), quality: 200)
        ]
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: localNode, localAlias: "EPINOD",
            forwarding: true, routes: routes,
            callsignForAlias: { $0 == "DRLNOD" ? "KE0NCQ" : nil })
        XCTAssertTrue(entries.isEmpty,
                      "alias and callsign are the same station: \(entries)")
    }

    func testUnresolvableAliasDestinationsAreStillSkipped() {
        // The route table really does hold these — "EVANS" and "DRLNOD"
        // are tactical names with no digit, and the destination field on
        // the wire is a callsign. Encoding one would emit bytes every
        // conforming parser rejects.
        let routes = [
            NetRomNodesBroadcast.KnownRoute(
                destination: AX25Address(call: "EVANS", ssid: 0), alias: "EVANS",
                nextHop: drlnod, quality: 61),
            NetRomNodesBroadcast.KnownRoute(
                destination: coscoNode, alias: "COSCO", nextHop: drlnod, quality: 120)
        ]
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: localNode, localAlias: "EPINOD",
            forwarding: true, routes: routes)
        XCTAssertEqual(entries.map(\.destination.display), ["KE0GB-7"],
                       "EVANS is an alias, not a callsign — it cannot ride that field")
    }

    func testWeNeverAdvertiseOurselves() {
        let routes = [
            NetRomNodesBroadcast.KnownRoute(
                destination: localNode, alias: "EPINOD", nextHop: drlnod, quality: 200)
        ]
        let entries = NetRomNodesBroadcast.advertisement(
            localNode: localNode, localAlias: "EPINOD",
            forwarding: true, routes: routes)
        XCTAssertTrue(entries.isEmpty, "a learned route to ourselves is not advertised either")
    }
}
