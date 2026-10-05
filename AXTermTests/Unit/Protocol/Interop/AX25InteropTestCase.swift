//
//  AX25InteropTestCase.swift
//  AXTermTests
//
//  Shared setup and checks for the interoperability suites. Each suite
//  builds a channel with AXTerm at one end, a scripted peer at the other
//  and any digipeaters in between, then runs scenarios on the virtual
//  clock and checks the invariants every interoperating link must hold.
//

import Foundation
import XCTest
@testable import AXTerm

@MainActor
class AX25InteropTestCase: XCTestCase {

    static let axtermCall = "N0AXT-1"

    /// AXTerm's link defaults as the app runs them: `TxAdaptiveSettings`
    /// defaults (K 2, paclen 128, N2 15, RTO 3 to 30 s) and the 4 s AX.25
    /// T1 setting, passed through
    /// `SessionCoordinator.syncSessionManagerConfigFromAdaptive` with
    /// in-session growth off, so no ceilings.
    static let appConfig = AX25SessionConfig(windowSize: 2, paclen: 128, maxRetries: 15,
                                            rtoMin: 3, rtoMax: 30, initialRto: 4,
                                            adaptiveTimeout: true)

    var clock: AX25VirtualClock!
    var channel: InteropChannel!
    var axterm: AXTermInteropStation!
    var peer: ScriptedAX25Peer!
    /// Digipeaters in the order AXTerm's frames meet them.
    var digis: [String] = []

    var peerCall: String { peer.address.display }
    /// The path as AXTerm writes it to reach the peer.
    var axtermPath: [String] { digis }
    /// The path as the peer writes it to reach AXTerm.
    var peerPath: [String] { digis.reversed() }

    /// The T1 AXTerm's link to the peer will run next: T1V (spec 7.3).
    var axtermT1: Double {
        axterm.manager.sessions.values.first?.timers.rto ?? 0
    }

    override func tearDown() {
        clock = nil
        channel = nil
        axterm = nil
        peer = nil
        super.tearDown()
    }

    /// AXTerm, then each digipeater, then the peer, each hearing only its
    /// neighbors.
    func build(_ profile: PeerProfile, peerCall: String = "W1PEER", digis: [String] = [],
               negotiate: Bool = true, config: AX25SessionConfig = AX25InteropTestCase.appConfig) {
        clock = AX25VirtualClock()
        channel = InteropChannel(clock: clock)
        axterm = AXTermInteropStation(call: Self.axtermCall, clock: clock, config: config)
        axterm.manager.negotiateV22 = negotiate
        axterm.channel = channel
        channel.add(axterm)
        self.digis = digis
        for call in digis {
            let digi = InteropDigipeater(call)
            digi.channel = channel
            channel.add(digi)
        }
        peer = ScriptedAX25Peer(peerCall, profile: profile, clock: clock)
        peer.channel = channel
        channel.add(peer)
    }

    func run(_ seconds: Double) { clock.advance(by: seconds) }

    /// Advance in small steps until `condition` holds or `limit` seconds pass.
    @discardableResult
    func run(until condition: () -> Bool, limit: Double) -> Bool {
        var elapsed = 0.0
        while elapsed < limit {
            if condition() { return true }
            clock.advance(by: 0.05)
            elapsed += 0.05
        }
        return condition()
    }

    var axSession: AX25Session? { axterm.session(with: peerCall) }

    var axDelivered: Data { axterm.delivered[peer.address.display] ?? Data() }

    // MARK: Scenarios used by every suite

    /// AXTerm calls the peer and the link comes up.
    func axtermConnects(file: StaticString = #filePath, line: UInt = #line) {
        axterm.connect(to: peerCall, via: axtermPath)
        let up = run(until: { axSession?.state == .connected && peer.isConnected }, limit: 120)
        XCTAssertTrue(up, "\(peer.profile.name): AXTerm's call did not connect. \(trace())", file: file, line: line)
    }

    /// The peer calls AXTerm and the link comes up.
    func peerConnects(to call: String = AX25InteropTestCase.axtermCall,
                      file: StaticString = #filePath, line: UInt = #line) {
        peer.connect(to: call, via: peerPath)
        let up = run(until: { axSession?.state == .connected && peer.isConnected }, limit: 120)
        XCTAssertTrue(up, "\(peer.profile.name): the peer's call did not connect. \(trace())", file: file, line: line)
    }

    /// Text that fills several frames, distinct at every offset so a
    /// reordered or repeated frame cannot pass for the right one.
    static func burst(_ count: Int, tag: String) -> Data {
        var text = ""
        var n = 0
        while text.utf8.count < count {
            text += "\(tag)\(String(format: "%04d", n)) "
            n += 1
        }
        return Data(text.utf8.prefix(count))
    }

    /// AXTerm sends `data`; the peer must receive it all, once, in order.
    func axtermSends(_ data: Data, limit: Double = 300,
                     file: StaticString = #filePath, line: UInt = #line) {
        let before = peer.delivered.count
        axterm.send(data, to: peerCall, via: axtermPath)
        run(until: { peer.delivered.count >= before + data.count && (axSession?.outstandingCount ?? 0) == 0 },
            limit: limit)
        XCTAssertEqual(peer.delivered.suffix(from: before), data,
                       "\(peer.profile.name): bytes AXTerm sent did not arrive once and in order. \(trace())",
                       file: file, line: line)
    }

    /// The peer sends `data`; AXTerm must deliver it all, once, in order.
    func peerSends(_ data: Data, limit: Double = 300,
                   file: StaticString = #filePath, line: UInt = #line) {
        let before = axDelivered.count
        peer.send(data)
        run(until: { axDelivered.count >= before + data.count && peer.outstanding == 0 }, limit: limit)
        XCTAssertEqual(axDelivered.suffix(from: before), data,
                       "\(peer.profile.name): bytes the peer sent were not delivered once and in order. \(trace())",
                       file: file, line: line)
    }

    // MARK: Invariants

    /// The peer saw nothing its spec version forbids.
    func assertNoViolations(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(peer.violations, [], "\(peer.profile.name)", file: file, line: line)
    }

    /// I-frames AXTerm sent more than once (same N(S) and payload).
    var axtermRetransmissions: Int {
        var seen: [String: Int] = [:]
        for entry in axterm.sent where entry.frame.frameType == "i" {
            seen["\(entry.frame.ns ?? -1):\(entry.frame.payload.base64EncodedString())", default: 0] += 1
        }
        return seen.values.reduce(0) { $0 + max(0, $1 - 1) }
    }

    /// Frames AXTerm put on the channel of one kind (by display text prefix).
    func axtermSent(_ prefix: String) -> [OutboundFrame] {
        axterm.sent.map(\.frame).filter { ($0.displayInfo ?? "").hasPrefix(prefix) }
    }

    /// Every I-frame AXTerm sent respected K and paclen as configured: growth
    /// is off, so the session keeps its starting values.
    func assertWindowAndPaclenHeld(k: Int = 2, paclen: Int = 128,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let iFrames = axterm.sent.map(\.frame).filter { $0.frameType == "i" }
        XCTAssertTrue(iFrames.allSatisfy { $0.payload.count <= paclen },
                      "an I field exceeded paclen \(paclen)", file: file, line: line)
        if let session = axSession {
            XCTAssertEqual(session.liveWindowSize, k, "K moved during the session", file: file, line: line)
            XCTAssertEqual(session.livePaclen, paclen, "paclen moved during the session", file: file, line: line)
        }
        // The window as the peer sees it: at no point more than K of
        // AXTerm's N(S) values beyond the peer's acknowledged V(R).
        XCTAssertLessThanOrEqual(axterm.maxOutstanding, k, "more than K frames outstanding", file: file, line: line)
    }

    /// The last few frames on the channel, for failure messages.
    func trace(_ count: Int = 40) -> String {
        "\nChannel:\n" + channel.log.suffix(count).map { entry in
            String(format: "  %7.2f %@ %@", entry.time, entry.sender, entry.frame?.description ?? "?")
        }.joined(separator: "\n") + "\nPeer violations: \(peer?.violations ?? [])"
    }
}
