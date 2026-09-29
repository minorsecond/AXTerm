//
//  GraphPathDraftingTests.swift
//  AXTermTests
//
//  Drawing a connect path on the graph: chain editing semantics, evidence-based
//  hop verdicts, and the resulting connect intent.
//

import XCTest
@testable import AXTerm

final class GraphPathDraftingTests: XCTestCase {
    private let origin = "K0EPI-7"

    private var context: PathDraftContext {
        PathDraftContext(
            roles: [
                "DRLNOD": [.node, .bbs, .digipeater],
                "KB5YZB-7": [.bbs, .connectedUser],
                "EATON": [.node],
                "W1AAA": [.connectedUser]
            ],
            digiRepeatCounts: ["DRLNOD": 450, "AB0VZ-7": 2],
            provenDigisForMyStation: ["DRLNOD"],
            preferredDisplay: [
                "K0EPI-7": "K0EPI-7",
                "DRLNOD": "DRLNOD",
                "KB5YZB-7": "KB5YZB-7"
            ],
            directHeardCounts: ["DRLNOD": 300, "KB5YZB-7": 40, "W1AAA": 12],
            provenDirectConnects: ["DRLNOD"]
        )
    }

    // MARK: - Chain editing

    func testChainEditingSemantics() {
        var chain: [String] = []
        chain = GraphPathDrafter.chain(after: "DRLNOD", current: chain, originKey: origin)
        XCTAssertEqual(chain, ["DRLNOD"])

        chain = GraphPathDrafter.chain(after: "KB5YZB-7", current: chain, originKey: origin)
        XCTAssertEqual(chain, ["DRLNOD", "KB5YZB-7"])

        // Clicking the last station removes it (undo)
        chain = GraphPathDrafter.chain(after: "KB5YZB-7", current: chain, originKey: origin)
        XCTAssertEqual(chain, ["DRLNOD"])

        // Prune back: click an earlier station in a longer chain
        chain = ["DRLNOD", "AB0VZ-7", "KB5YZB-7"]
        chain = GraphPathDrafter.chain(after: "DRLNOD", current: chain, originKey: origin)
        XCTAssertEqual(chain, ["DRLNOD"], "Clicking an earlier hop prunes the chain back to it")

        // Clicking the origin clears everything
        chain = GraphPathDrafter.chain(after: origin, current: ["DRLNOD"], originKey: origin)
        XCTAssertEqual(chain, [])
    }

    // MARK: - Verdicts

    func testHopVerdictsFollowEvidence() {
        let draft = GraphPathDrafter.makeDraft(
            originKey: origin,
            chain: ["DRLNOD", "AB0VZ-7", "EATON", "W1AAA", "KB5YZB-7"],
            context: context
        )

        XCTAssertEqual(draft.viaHops.count, 4)
        XCTAssertEqual(draft.viaHops[0].verdict, .provenDigi(repeats: 450),
                       "DRLNOD has repeated my frames")
        XCTAssertEqual(draft.viaHops[1].verdict, .observedDigi(repeats: 2),
                       "AB0VZ-7 digipeats, but never for me")
        XCTAssertEqual(draft.viaHops[2].verdict, .nodeNotDigi,
                       "EATON is a node with no digipeat evidence")
        XCTAssertEqual(draft.viaHops[3].verdict, .unproven)
        XCTAssertEqual(draft.destinationDisplay, "KB5YZB-7")
        XCTAssertTrue(draft.destinationIsInfrastructure, "KB5YZB-7 is a BBS")
        XCTAssertFalse(draft.warnings.isEmpty, "Node-as-digi and unproven hops must warn")
        XCTAssertTrue(draft.warnings.contains { $0.contains("digi hops") },
                      "More than 2 vias warns about throughput")
    }

    // MARK: - Intent construction

    func testDirectDraftBuildsAX25Intent() {
        let draft = GraphPathDrafter.makeDraft(originKey: origin, chain: ["W1AAA"], context: context)
        let intent = draft.connectIntent()
        XCTAssertEqual(intent?.kind, .ax25Direct)
        XCTAssertEqual(intent?.to, "W1AAA")
        XCTAssertEqual(draft.connectMode, .ax25)
    }

    func testViaDraftBuildsDigiPathIntent() {
        // The everyday case: C KB5YZB-7 via DRLNOD.
        let draft = GraphPathDrafter.makeDraft(
            originKey: origin,
            chain: ["DRLNOD", "KB5YZB-7"],
            context: context
        )
        let intent = draft.connectIntent()

        XCTAssertEqual(intent?.to, "KB5YZB-7")
        if case .ax25ViaDigis(let vias)? = intent?.kind {
            XCTAssertEqual(vias.map(\.stringValue), ["DRLNOD"])
        } else {
            XCTFail("Expected an AX.25 via-digi intent")
        }
        XCTAssertEqual(draft.connectMode, .ax25ViaDigi)
        XCTAssertEqual(intent?.suggestedRoutePreview, "K0EPI-7 \u{2192} DRLNOD \u{2192} KB5YZB-7")
        XCTAssertEqual(intent?.validationErrors, [])
        XCTAssertTrue(draft.warnings.isEmpty, "A proven single-digi path is clean")
    }

    func testOriginOnlyDraftIsNotConnectable() {
        let draft = GraphPathDrafter.makeDraft(originKey: origin, chain: [], context: context)
        XCTAssertFalse(draft.isConnectable)
        XCTAssertNil(draft.connectIntent())
        XCTAssertEqual(draft.chainKeys, [origin])
    }

    func testPreferredDisplayResolvesTransmittedCallsigns() {
        // Station-grouped identity: the drawn "KB5YZB" node must resolve to the
        // SSID actually heard on air, since that string goes on the air.
        let grouped = PathDraftContext(
            roles: [:],
            digiRepeatCounts: ["DRLNOD": 10],
            provenDigisForMyStation: [],
            preferredDisplay: ["KB5YZB": "KB5YZB-7", "DRLNOD": "DRLNOD", "K0EPI": "K0EPI-7"]
        )
        let draft = GraphPathDrafter.makeDraft(
            originKey: "K0EPI",
            chain: ["DRLNOD", "KB5YZB"],
            context: grouped
        )
        XCTAssertEqual(draft.destinationDisplay, "KB5YZB-7")
        XCTAssertEqual(draft.connectIntent()?.to, "KB5YZB-7")
    }

    // MARK: - First-hop reachability

    func testFirstHopProvenByPriorDirectConnect() {
        // DRLNOD has completed a direct session with my station before.
        let draft = GraphPathDrafter.makeDraft(
            originKey: origin, chain: ["DRLNOD", "KB5YZB-7"], context: context
        )
        XCTAssertEqual(draft.firstHopReachability, .provenConnect)
        XCTAssertTrue(draft.warnings.isEmpty)
    }

    func testFirstHopHeardDirectWithoutSessionEvidence() {
        // KB5YZB-7 is heard direct but we have never connected to him.
        let draft = GraphPathDrafter.makeDraft(
            originKey: origin, chain: ["KB5YZB-7"], context: context
        )
        XCTAssertEqual(draft.firstHopReachability, .heardDirect(frames: 40))
        XCTAssertTrue(draft.warnings.isEmpty, "Heard-direct is evidence enough; no warning")
    }

    func testFirstHopNeverHeardDirectWarns() {
        // EATON has no direct-heard evidence at all: my RF may not reach it.
        let draft = GraphPathDrafter.makeDraft(
            originKey: origin, chain: ["EATON", "W1AAA"], context: context
        )
        XCTAssertEqual(draft.firstHopReachability, .notHeardDirect)
        XCTAssertTrue(draft.warnings.contains { $0.contains("never heard direct") },
                      "An unreachable first hop dooms the whole path and must warn")
    }

    func testEmptyChainHasNoReachability() {
        let draft = GraphPathDrafter.makeDraft(originKey: origin, chain: [], context: context)
        XCTAssertNil(draft.firstHopReachability)
    }
}
