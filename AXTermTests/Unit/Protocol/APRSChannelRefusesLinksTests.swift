//
//  APRSChannelRefusesLinksTests.swift
//  AXTermTests
//
//  A shared APRS frequency is a beacon channel (RadioProfile.runsPacketServices).
//  The node, ping and mailbox already stayed off APRS radios, but a SABM
//  arriving on one was still answered UA, so anything that answers calls,
//  Winlink peer-to-peer included, could take it there. The operator
//  (2026-10-06): never ping on an APRS channel, nor listen for Winlink
//  peer-to-peer, or anything like it. On an APRS radio the station answers
//  a call the way a station that cannot accept one does: DM.
//

import XCTest
@testable import AXTerm

@MainActor
final class APRSChannelRefusesLinksTests: XCTestCase {
    private let me = AX25Address(call: "K0EPI", ssid: 5)
    private let caller = AX25Address(call: "N0CALL", ssid: 7)
    private let aprs = RadioID(rawValue: "aprs-radio")

    private func manager() -> AX25SessionManager {
        let manager = AX25SessionManager(localCallsign: me, clock: AX25VirtualClock())
        manager.refusesInboundLinks = { [aprs] radio in radio == aprs }
        return manager
    }

    func testACallOnAnAPRSRadioIsRefusedWithDM() throws {
        let manager = manager()
        let answer = try XCTUnwrap(manager.handleInboundSABM(from: caller, to: me, path: DigiPath(), radio: aprs))
        XCTAssertEqual(answer.displayInfo, "DM")
        XCTAssertEqual(answer.source.display, "K0EPI-5", "from the address that was called")
        XCTAssertEqual(answer.radio, aprs)
        XCTAssertNil(manager.existingSession(for: caller, path: DigiPath(), radio: aprs), "no link is opened")
    }

    func testACallOnAPacketRadioIsStillAnswered() throws {
        let manager = manager()
        let answer = try XCTUnwrap(manager.handleInboundSABM(from: caller, to: me, path: DigiPath(), radio: .primary))
        XCTAssertEqual(answer.displayInfo, "UA")
    }

    func testAPolledXIDOnAnAPRSRadioIsRefusedAndAnUnpolledOneIgnored() {
        let manager = manager()
        let polled = manager.handleInboundXID(from: caller, to: me, path: DigiPath(), radio: aprs,
                                              info: AX25XIDParameters().encoded(isCommand: true), isCommand: true, pf: true)
        XCTAssertEqual(polled.map(\.displayInfo), ["DM"])
        let quiet = manager.handleInboundXID(from: caller, to: me, path: DigiPath(), radio: aprs,
                                             info: AX25XIDParameters().encoded(isCommand: true), isCommand: true, pf: false)
        XCTAssertTrue(quiet.isEmpty)
    }

    /// A link the operator opened themselves stays theirs: the peer's own
    /// SABM (a link reset) reaches it.
    func testALinkWeOpenedIsNotRefused() throws {
        let manager = manager()
        _ = manager.connect(to: caller, path: DigiPath(), radio: aprs)
        let answer = manager.handleInboundSABM(from: caller, to: me, path: DigiPath(), radio: aprs)
        XCTAssertNotEqual(answer?.displayInfo, "DM")
    }

    func testNoPingGoesOutOnAnAPRSRadioEvenWhenAsked() {
        let prober = PingProber(defaults: TestDefaults.make("APRSChannelRefusesLinksTests"))
        var sent: [OutboundFrame] = []
        prober.sendFrame = { frame in sent.append(frame); return true }
        prober.localAddress = { [me] _ in me }
        prober.candidateProvider = { [aprs] in
            [PingPolicy.Candidate(call: "N0CALL-7", source: .heardDirect, lastActivity: Date(), radio: aprs)]
        }
        prober.mayProbe = { [aprs] radio in radio != aprs }
        var notes: [String] = []
        prober.onNote = { notes.append($0) }

        prober.probeNow("N0CALL-7")

        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(notes.contains { $0.contains("APRS") }, "\(notes)")
    }

    /// The Winlink settings name the radios a call can be answered on, and
    /// none when every radio is on an APRS channel.
    func testWinlinkAnswersOnlyOnPacketRadios() {
        var packet = RadioProfile(id: .primary, name: "Base")
        packet.enabled = true
        var beacon = RadioProfile(id: aprs, name: "IC-705")
        beacon.enabled = true
        RadioChannel.aprs.apply(to: &beacon)
        XCTAssertEqual(ServiceRadios.winlinkPeerToPeer([packet, beacon]), ["Base"])
        XCTAssertEqual(ServiceRadios.winlinkPeerToPeer([beacon]), [])
    }
}
