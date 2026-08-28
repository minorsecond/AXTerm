//
//  NodeCapabilityTests.swift
//  AXTermTests
//
//  Pins the node-software classifier and the capability verdict lattice.
//  Fingerprint lines are the field captures of 2026-08-28: DRLNOD (KE0NCQ),
//  a Kantronics KA-Node, and KB5YZB-7 (YZBBPQ), a BPQ node. The verdict
//  gates harvested-route synthesis, so a wrong "can route NET/ROM" answer
//  fabricates routes through stations that cannot carry them — the mistake
//  this whole model exists to prevent.
//

import XCTest
@testable import AXTerm

@MainActor
final class NodeCapabilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    // MARK: - Classifier: lines that are fingerprints

    func testBpqBannerIsRecognized() {
        XCTAssertEqual(
            NodeSoftwareClassifier.classify(line: "YZBBPQ:KB5YZB-7} Aurora, CO Area BPQ Packet Node — Network Node Server"),
            .bpqBanner,
            "banner check runs first even when the line would also match other shapes")
        XCTAssertEqual(
            NodeSoftwareClassifier.classify(line: "Welcome to the Network Node Server"),
            .bpqBanner)
    }

    func testBpqMenuIsRecognized() {
        XCTAssertEqual(
            NodeSoftwareClassifier.classify(line: "BBS CHAT CONNECT BYE INFO LISTEN NODES PORTS ROUTES USERS MHEARD"),
            .bpqMenu)
    }

    func testBpqPromptShapeIsRecognized() {
        XCTAssertEqual(NodeSoftwareClassifier.classify(line: "K0EPI-7:DRLNOD}"), .bpqPrompt)
        XCTAssertEqual(NodeSoftwareClassifier.classify(line: "KB5YZB-7:YZBBPQ}"), .bpqPrompt)
    }

    func testKaNodeMenuIsRecognized() {
        XCTAssertEqual(
            NodeSoftwareClassifier.classify(line: "ENTER COMMAND: B,C,J,N, or Help ?"),
            .kaNodeMenu)
    }

    func testKaNodeLinkBannerIsRecognized() {
        XCTAssertEqual(
            NodeSoftwareClassifier.classify(line: "###CONNECTED TO NODE DRLNOD(KE0NCQ) CHANNEL A"),
            .kaNodeLinkBanner)
    }

    // MARK: - Classifier: lines that are deliberately NOT fingerprints

    /// Other software prints a generic "ENTER COMMAND" prompt too; only the
    /// exact Kantronics command set is the fingerprint.
    func testBareEnterCommandIsNotAFingerprint() {
        XCTAssertNil(NodeSoftwareClassifier.classify(line: "ENTER COMMAND:"))
    }

    /// Both families print it, so it proves nothing about which one spoke.
    func testLinkMadeIsNotAFingerprint() {
        XCTAssertNil(NodeSoftwareClassifier.classify(line: "###LINK MADE"))
    }

    func testOrdinaryLinesAreNotFingerprints() {
        XCTAssertNil(NodeSoftwareClassifier.classify(line: "Hello Ross, good to hear you on the air"))
        XCTAssertNil(NodeSoftwareClassifier.classify(line: "> 1 KE0GB-7 192 91"), "a ROUTES row is the scraper's business, not the classifier's")
        XCTAssertNil(NodeSoftwareClassifier.classify(line: "Msg#  TSLD  Dim  To  From  Subject"))
        XCTAssertNil(NodeSoftwareClassifier.classify(line: ""))
        XCTAssertNil(NodeSoftwareClassifier.classify(line: "I might CONNECT later and say BYE"),
                     "two menu words in prose are conversation, not a menu")
    }

    // MARK: - Verdict lattice

    private func directory(recording pairs: [(NodeSoftwareObservation.Kind, String)],
                           for call: String) -> NodeCapabilityDirectory {
        var directory = NodeCapabilityDirectory()
        for (offset, pair) in pairs.enumerated() {
            directory.record(pair.0, callsign: call, sourceText: pair.1,
                             at: now.addingTimeInterval(TimeInterval(offset)))
        }
        return directory
    }

    func testKaEvidenceAloneMeansCannotRouteNetRom() {
        let dir = directory(recording: [
            (.kaNodeLinkBanner, "###CONNECTED TO NODE DRLNOD(KE0NCQ) CHANNEL A"),
            (.kaNodeMenu, "ENTER COMMAND: B,C,J,N, or Help ?")
        ], for: "KE0NCQ")
        XCTAssertEqual(dir.family(for: "KE0NCQ"), .kaNode)
        XCTAssertEqual(dir.canRouteNetRom("KE0NCQ"), false)
        XCTAssertTrue(dir.evidence(for: "KE0NCQ")?.contains("cannot route NET/ROM") ?? false)
    }

    func testBpqEvidenceMeansCanRouteNetRom() {
        let dir = directory(recording: [
            (.bpqBanner, "Network Node Server")
        ], for: "KB5YZB-7")
        XCTAssertEqual(dir.family(for: "KB5YZB-7"), .bpq)
        XCTAssertEqual(dir.canRouteNetRom("KB5YZB-7"), true)
        XCTAssertTrue(dir.evidence(for: "KB5YZB-7")?.contains("Network Node Server") ?? false,
                      "the verdict quotes the line that earned it")
    }

    func testNodesBroadcastAloneIsGroundTruth() {
        let dir = directory(recording: [
            (.nodesBroadcast, "NET/ROM routing broadcast (PID 0xCF to NODES)")
        ], for: "W0XYZ-4")
        XCTAssertEqual(dir.family(for: "W0XYZ-4"), .netromOther)
        XCTAssertEqual(dir.canRouteNetRom("W0XYZ-4"), true)
    }

    /// Conflicting fingerprints get no verdict — refusing to guess is the
    /// point of keeping evidence — until ground truth resolves it.
    func testConflictYieldsNoVerdictUntilGroundTruthArrives() {
        var dir = directory(recording: [
            (.kaNodeMenu, "ENTER COMMAND: B,C,J,N, or Help ?"),
            (.bpqBanner, "Network Node Server")
        ], for: "N0CONF")
        XCTAssertNil(dir.family(for: "N0CONF"))
        XCTAssertNil(dir.canRouteNetRom("N0CONF"))
        XCTAssertTrue(dir.evidence(for: "N0CONF")?.contains("no verdict") ?? false)

        dir.record(.nodesBroadcast, callsign: "N0CONF",
                   sourceText: "NET/ROM routing broadcast", at: now.addingTimeInterval(10))
        XCTAssertEqual(dir.canRouteNetRom("N0CONF"), true)
        XCTAssertEqual(dir.family(for: "N0CONF"), .bpq,
                       "ground truth plus BPQ fingerprints resolves to BPQ")
    }

    /// A borrowed-SSID dial can come from a crossband arrangement too, so it
    /// corroborates but never decides.
    func testBorrowedSsidDialAloneDecidesNothing() {
        let dir = directory(recording: [
            (.borrowedSsidDial, "SABM as K0EPI-14 toward KE0GB-7")
        ], for: "KB5YZB-7")
        XCTAssertNil(dir.family(for: "KB5YZB-7"))
        XCTAssertNil(dir.canRouteNetRom("KB5YZB-7"))
    }

    func testUnknownStationHasNoVerdict() {
        XCTAssertNil(NodeCapabilityDirectory().canRouteNetRom("W1ABC"))
    }

    // MARK: - Replay discipline and persistence

    /// Re-seeing the same banner keeps one observation per kind, timestamps
    /// moving only forward — verdicts are derived, so nothing can inflate.
    func testReplayKeepsOneObservationPerKind() {
        var dir = NodeCapabilityDirectory()
        dir.record(.bpqBanner, callsign: "KB5YZB-7", sourceText: "Network Node Server", at: now)
        dir.record(.bpqBanner, callsign: "KB5YZB-7", sourceText: "Network Node Server", at: now.addingTimeInterval(60))
        dir.record(.bpqBanner, callsign: "KB5YZB-7", sourceText: "Network Node Server", at: now.addingTimeInterval(-60))

        let entry = dir.entries["KB5YZB-7"]
        XCTAssertEqual(entry?.observations.count, 1)
        XCTAssertEqual(entry?.observations.first?.observedAt, now.addingTimeInterval(60),
                       "newest sighting wins; an older replay never rewinds")
    }

    func testDirectoryRoundTripsThroughCodable() throws {
        let dir = directory(recording: [
            (.kaNodeMenu, "ENTER COMMAND: B,C,J,N, or Help ?")
        ], for: "KE0NCQ")
        let data = try JSONEncoder().encode(dir.entries)
        let decoded = try JSONDecoder().decode([String: NodeCapabilityDirectory.Entry].self, from: data)
        XCTAssertEqual(NodeCapabilityDirectory(entries: decoded).canRouteNetRom("KE0NCQ"), false)
    }

    // MARK: - Store ingestion

    // Store tests are async on purpose: a MainActor-isolated
    // ObservableObject constructed in a synchronous test method dies with
    // SIGABRT under this project's default-isolation settings (see the
    // NodeAliasStore tests and AXTermTests history for the same rule).
    func testStoreLearnsFromSessionLinesAndPersists() async {
        let defaults = UserDefaults(suiteName: "NodeCapabilityTests-\(UUID().uuidString)")!
        let store = NodeCapabilityStore(defaults: defaults)
        store.ingest(line: "###CONNECTED TO NODE DRLNOD(KE0NCQ) CHANNEL A", peer: "KE0NCQ", at: now)
        XCTAssertEqual(store.canRouteNetRom("KE0NCQ"), false)

        // A second store on the same defaults sees the verdict — restarts
        // keep what a session taught.
        let reloaded = NodeCapabilityStore(defaults: defaults)
        XCTAssertEqual(reloaded.canRouteNetRom("KE0NCQ"), false)
    }

    func testStoreLearnsGroundTruthFromPackets() async {
        let defaults = UserDefaults(suiteName: "NodeCapabilityTests-\(UUID().uuidString)")!
        let store = NodeCapabilityStore(defaults: defaults)

        let info = Data([0xFF])
        let broadcast = Packet(
            timestamp: now,
            from: AX25Address(call: "KB5YZB", ssid: 7),
            to: AX25Address(call: "NODES"),
            via: [],
            frameType: .ui,
            pid: 0xCF,
            info: info,
            rawAx25: info,
            infoText: nil
        )
        store.ingest(packets: [broadcast])
        XCTAssertEqual(store.canRouteNetRom("KB5YZB-7"), true)

        // An ordinary UI beacon teaches nothing.
        let beacon = Packet(
            timestamp: now,
            from: AX25Address(call: "KE0NCQ"),
            to: AX25Address(call: "ID"),
            via: [],
            frameType: .ui,
            pid: 0xF0,
            info: info,
            rawAx25: info,
            infoText: "KE0NCQ/R DRL/D DRLBBS/B DRLNOD/N"
        )
        store.ingest(packets: [beacon])
        XCTAssertNil(store.canRouteNetRom("KE0NCQ"),
                     "an ID beacon's /N declaration is a service claim, not capability evidence")
    }

    // MARK: - Role inference integration

    /// DRLNOD's ID beacon declares `/N`, and it is still a KA-Node: the
    /// fingerprint blocks the NET/ROM-node role and earns the relay role.
    func testKaNodeVerdictBlocksTheNetRomNodeRole() {
        let declared = StationServiceParser.Declaration(
            callsign: "KE0NCQ", service: .node, alias: "DRLNOD",
            sourceText: "KE0NCQ/R DRL/D DRLBBS/B DRLNOD/N")

        let roles = NodeProfile.inferRoles(
            callsign: "KE0NCQ",
            localCallsign: "K0EPI-7",
            heard: nil,
            isAlias: false,
            netRomDeclaration: .aliasAnnouncement("DRLNOD"),
            digipeaterCallsigns: [],
            declaredServices: [declared],
            winlink: nil,
            nodeSoftware: .kaNode)

        XCTAssertTrue(roles.contains(.kaNodeRelay))
        XCTAssertFalse(roles.contains(.netromNode),
                       "a station that cannot route NET/ROM must not wear the NET/ROM-node label")
    }

    func testBpqVerdictStillEarnsTheNetRomNodeRole() {
        let roles = NodeProfile.inferRoles(
            callsign: "KB5YZB-7",
            localCallsign: "K0EPI-7",
            heard: nil,
            isAlias: false,
            netRomDeclaration: .softwareFingerprint(family: .bpq, detail: "banner"),
            digipeaterCallsigns: [],
            declaredServices: [],
            winlink: nil,
            nodeSoftware: .bpq)
        XCTAssertTrue(roles.contains(.netromNode))
        XCTAssertFalse(roles.contains(.kaNodeRelay))
    }
}
