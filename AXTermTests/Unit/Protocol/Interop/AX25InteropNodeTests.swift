//
//  AX25InteropNodeTests.swift
//  AXTermTests
//
//  AXTerm against a BPQ32/LinBPQ node, and against the Kantronics-style
//  node (DRLNOD) AXTerm relays through. The L2 values are the TestRig
//  LinBPQ's (TestRig/linbpq/bpq32.cfg). The text a node prints comes only
//  from captures already quoted in AXTerm's code: the TestRig CTEXT, the
//  `ALIAS:CALL}` prompt glued to the echoed command (NodeCapability.swift),
//  "Connected to COSCO:KE0GB-7" for a BPQ connect (NetRomRelayPlan.swift),
//  and for the Kantronics node "###CONNECTED TO NODE DRLNOD(KE0NCQ)
//  CHANNEL A", "ENTER COMMAND: B,C,J,N, or Help ?" and "###LINK MADE"
//  (NodeCapability.swift, ManualRelayDetector.swift). What a node prints
//  for anything else is not modeled: an unknown command gets only the
//  prompt back.
//

import XCTest
@testable import AXTerm

/// A node's command interpreter on top of a scripted link.
@MainActor
final class ScriptedNode {
    enum Family {
        case bpq(alias: String, call: String)
        case kaNode(name: String, call: String)
    }

    let link: ScriptedAX25Peer
    let family: Family
    /// Stations the node can connect onward to, and the banner each sends
    /// once connected.
    var reachable: [String: String] = [:]
    private(set) var commands: [String] = []
    private(set) var relayedTo: String?

    init(link: ScriptedAX25Peer, family: Family) {
        self.link = link
        self.family = family
        link.onConnected = { [weak self] in self?.greet() }
        link.onLine = { [weak self] line in self?.command(line) }
    }

    private var prompt: String {
        switch family {
        case .bpq(let alias, let call): return "\(alias):\(call)}"
        case .kaNode: return "ENTER COMMAND: B,C,J,N, or Help ?"
        }
    }

    private func greet() {
        switch family {
        case .bpq(let alias, _):
            link.send("Welcome to \(alias), the AXTerm test rig node.\rTry NODES, ROUTES, MH, INFO, BYE.\r")
        case .kaNode(let name, let call):
            link.send("###CONNECTED TO NODE \(name)(\(call)) CHANNEL A\r\(prompt)\r")
        }
    }

    private func command(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespaces)
        commands.append(text)
        if let far = relayedTo {
            // Once relayed, lines go to the far station; the model's far
            // station just acknowledges what it got.
            link.send("\(far) got: \(text)\r")
            return
        }
        let words = text.uppercased().split(separator: " ").map(String.init)
        switch words.first {
        case "BYE", "B":
            link.disconnect()
        case "C", "CONNECT":
            guard words.count > 1, let banner = reachable[words[1]] else {
                link.send(echoed(text))
                return
            }
            relayedTo = words[1]
            switch family {
            case .bpq:
                link.send("\(prompt) Connected to \(words[1])\r\(banner)\r")
            case .kaNode:
                link.send("###LINK MADE\r\(banner)\r")
            }
        case "NODES", "N":
            let list = reachable.keys.sorted().joined(separator: "  ")
            switch family {
            case .bpq: link.send("\(prompt) Nodes\r\(list)\r")
            case .kaNode: link.send("\(list)\r\(prompt)\r")
            }
        default:
            link.send(echoed(text))
        }
    }

    private func echoed(_ text: String) -> String {
        switch family {
        case .bpq: return "\(prompt) \(text)\r"
        case .kaNode: return "\(prompt)\r"
        }
    }
}

@MainActor
final class AX25InteropNodeTests: AX25InteropTestCase {

    private var node: ScriptedNode!

    override func tearDown() {
        node = nil
        super.tearDown()
    }

    private func buildBPQ(digis: [String] = []) {
        build(.bpq(), peerCall: "BPQTST-7", digis: digis)
        node = ScriptedNode(link: peer, family: .bpq(alias: "TSTNOD", call: "BPQTST-7"))
        node.reachable = ["FARNOD": "Welcome to FARNOD:BPQTX2-7 Network Node Server"]
    }

    private func buildKaNode(digis: [String] = []) {
        var profile = PeerProfile.tnc2(xid: .frmr)
        profile.name = "KA-Node"
        build(profile, peerCall: "KE0NCQ-7", digis: digis)
        node = ScriptedNode(link: peer, family: .kaNode(name: "DRLNOD", call: "KE0NCQ"))
        node.reachable = ["KB5YZB-7": "Welcome to YZBBPQ:KB5YZB-7 Network Node Server"]
    }

    /// Lines AXTerm delivered from the node, as the terminal splits them.
    private var nodeLines: [String] {
        String(decoding: axDelivered, as: UTF8.self)
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" }).map(String.init)
    }

    // MARK: - L2 matrix against BPQ

    func testAXTermCalls() { scenarioAXTermCalls(.bpq()) }
    func testBPQCalls() { scenarioPeerCalls(.bpq()) }
    func testAXTermFrameLost() { scenarioAXTermFrameLost(.bpq()) }
    func testBPQFrameLost() { scenarioPeerFrameLost(.bpq()) }
    func testLostAck() { scenarioAckLost(.bpq()) }
    func testRNR() { scenarioPeerBusy(.bpq()) }
    func testLastFrameLostRecoveredByT1() { scenarioLastFrameLost(.bpq()) }
    func testBPQReconnectsOverStaleLink() { scenarioPeerReconnectsOverStaleLink(.bpq()) }
    func testKeepalive() { scenarioKeepalive(.bpq()) }
    func testFRMR() { scenarioFRMR(.bpq()) }
    func testBPQStaleLink() { scenarioPeerHoldsStaleLink(.bpq()) }
    func testAXTermStaleLink() { scenarioAXTermHoldsStaleLink(.bpq()) }
    func testAddressing() { scenarioAddressing(.bpq()) }
    func testXIDDrawsDM() { scenarioXIDOnce(.bpq(), expectSREJ: false) }

    // MARK: - The node conversation

    /// Connect, read the greeting, run node commands, connect onward and
    /// leave with BYE. Every line arrives once and in order, and the node
    /// gets each command exactly as typed.
    func testBPQGreetingCommandsRelayAndBye() {
        for path in Self.paths {
            buildBPQ(digis: path)
            axtermConnects()
            run(until: { nodeLines.count >= 2 }, limit: 60)
            XCTAssertEqual(nodeLines.first, "Welcome to TSTNOD, the AXTerm test rig node.", "path \(path) \(trace())")

            axtermSends(Data("NODES\r".utf8))
            run(until: { nodeLines.contains("TSTNOD:BPQTST-7} Nodes") && nodeLines.contains("FARNOD") }, limit: 60)
            XCTAssertTrue(nodeLines.contains("TSTNOD:BPQTST-7} Nodes"), "path \(path) \(trace())")

            axtermSends(Data("C FARNOD\r".utf8))
            run(until: { nodeLines.contains { $0.contains("Network Node Server") } }, limit: 60)
            XCTAssertTrue(nodeLines.contains("TSTNOD:BPQTST-7} Connected to FARNOD"), "path \(path) \(nodeLines)")
            XCTAssertTrue(nodeLines.contains("Welcome to FARNOD:BPQTX2-7 Network Node Server"), "path \(path)")

            axtermSends(Data("hello far end\r".utf8))
            run(until: { nodeLines.contains("FARNOD got: hello far end") }, limit: 60)
            XCTAssertTrue(nodeLines.contains("FARNOD got: hello far end"), "path \(path) \(nodeLines)")
            XCTAssertEqual(node.commands, ["NODES", "C FARNOD", "hello far end"], "path \(path)")
            XCTAssertEqual(axtermRetransmissions, 0, "path \(path) \(trace())")
            assertNoViolations()
        }
    }

    func testByeEndsTheLinkFromTheNodeSide() {
        buildBPQ()
        axtermConnects()
        axtermSends(Data("BYE\r".utf8))
        run(until: { axSession?.state == .disconnected && peer.state == .disconnected }, limit: 60)
        XCTAssertEqual(axSession?.state, .disconnected, trace())
        XCTAssertEqual(peer.state, .disconnected)
        assertNoViolations()
    }

    /// The Kantronics-style relay AXTerm drives by hand: C KB5YZB-7 draws
    /// ###LINK MADE, which ManualRelayDetector must see as established,
    /// followed by the far node's banner.
    func testKaNodeLinkMadeIsSeenByTheRelayDetector() {
        for path in [[String](), ["DIGI1"], ["DIGI1", "DIGI2"]] {
            buildKaNode(digis: path)
            axtermConnects()
            run(until: { nodeLines.count >= 2 }, limit: 60)
            XCTAssertEqual(nodeLines.first, "###CONNECTED TO NODE DRLNOD(KE0NCQ) CHANNEL A", "path \(path) \(trace())")

            var detector = ManualRelayDetector()
            for line in nodeLines { detector.processIncoming(line) }
            XCTAssertTrue(detector.hasSeenNodePrompt, "path \(path)")
            let seen = nodeLines.count

            detector.processOutgoing("C KB5YZB-7")
            axtermSends(Data("C KB5YZB-7\r".utf8))
            run(until: { nodeLines.contains { $0.contains("Network Node Server") } }, limit: 60)
            for line in nodeLines.dropFirst(seen) { detector.processIncoming(line) }
            XCTAssertEqual(detector.state, .established(destination: "KB5YZB-7"), "path \(path) \(nodeLines)")
            XCTAssertEqual(nodeLines.last, "Welcome to YZBBPQ:KB5YZB-7 Network Node Server")
            assertNoViolations()
        }
    }
}
