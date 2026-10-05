//
//  APRSThirdPartyTests.swift
//  AXTermTests
//
//  Third-party frames (`}`), the form an igate uses to put a packet from
//  APRS-IS onto RF, are decoded as the packet inside them and credited to
//  the station that sent it, never to the igate.
//
//  Smoke run 2026-10-03-1, issue 27: on 144.390 every weather report and
//  object heard in 15 minutes came through igates this way, and the terminal
//  printed them raw.
//

import XCTest
@testable import AXTerm

final class APRSThirdPartyTests: XCTestCase {

    private func digest(_ info: String, to destination: String = "APRS") -> APRSDigest? {
        APRSDigest.parse(destination: destination, info: Data(info.utf8))
    }

    func testTheHeaderNamesSourceDestinationPathAndGateway() throws {
        let relay = try XCTUnwrap(APRSThirdParty.unwrap(
            info: Data("}KJ5PEC-13>APRS,TCPIP,W0NED*:!3923.61N/10440.49W_".utf8)))
        XCTAssertEqual(relay.source, "KJ5PEC-13")
        XCTAssertEqual(relay.destination, "APRS")
        XCTAssertEqual(relay.path, ["TCPIP", "W0NED*"])
        XCTAssertEqual(relay.gateway, "W0NED")
        XCTAssertTrue(relay.viaInternet)
        XCTAssertEqual(String(data: relay.payload, encoding: .ascii), "!3923.61N/10440.49W_")
    }

    func testAnythingElseIsNotThirdParty() {
        for info in ["!3923.61N/10440.49W#", "}", "}no-arrow:x", "}>APRS:x", "}SRC>:x"] {
            XCTAssertNil(APRSThirdParty.unwrap(info: Data(info.utf8)), info)
        }
    }

    func testARelayedPositionIsTheSourcesPosition() throws {
        let d = try XCTUnwrap(digest("}KJ5PEC-13>APRS,TCPIP,W0NED*:!3923.61N/10440.49W#APRS Voyager"))
        guard case .relayed(let relay, .position(let report)) = d else { return XCTFail("got \(d)") }
        XCTAssertEqual(relay.source, "KJ5PEC-13")
        XCTAssertEqual(report.latitude, 39.3935, accuracy: 0.001)
        XCTAssertEqual(d.originator(heardFrom: "W0NED"), "KJ5PEC-13")
        XCTAssertEqual(d.messageClass, .beacon)

        let line = APRSDigestLine.text(for: d)
        XCTAssertTrue(line.hasPrefix("KJ5PEC-13: 39."), line)
        XCTAssertTrue(line.hasSuffix("relayed by W0NED from the internet"), line)
    }

    /// Mic-E keeps its latitude in the destination, and in a relayed frame
    /// that is the inner destination, not the igate's.
    func testARelayedMicEReadsItsLatitudeFromTheInnerDestination() throws {
        let d = try XCTUnwrap(digest("}KF0KBL-1>SYSQSQ,TCPIP,W0NED*:\u{60}pEzn6cR/\u{60}\"Hd]_4", to: "APRS"))
        guard case .relayed(_, .position(let report)) = d else { return XCTFail("got \(d)") }
        XCTAssertEqual(report.latitude, 39.52, accuracy: 0.1)
        XCTAssertEqual(report.longitude, -104.70, accuracy: 0.1)
    }

    func testARelayedObjectAndWeatherAreDecoded() throws {
        let object = try XCTUnwrap(digest("}KC0ABC>APRS,TCPIP,W3OO-1*:;SPOTTER  *161843z3923.61N/10440.49W/note"))
        guard case .relayed(_, .object) = object else { return XCTFail("got \(object)") }
        let weather = try XCTUnwrap(digest("}KC0WX>APRS,TCPIP,W3OO-1*:_10090556c220s004g005t077"))
        guard case .relayed(_, .weather) = weather else { return XCTFail("got \(weather)") }
    }

    func testARelayedMessageStillReadsAndFilesUnderData() throws {
        let d = try XCTUnwrap(digest("}YF3CJU-5>APDR16,TCPIP,K5RHD-10*::AK0U-4   :Hello"))
        guard case .relayed(_, .message(.message(let addressee, let text, _))) = d else { return XCTFail("got \(d)") }
        XCTAssertEqual(addressee, "AK0U-4")
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(d.messageClass, .data)
    }

    /// A relay between two radio channels says so, rather than claiming the
    /// internet.
    func testARadioRelayIsNotCalledInternet() throws {
        let d = try XCTUnwrap(digest("}K0EPI-7>APZAXT,WIDE1-1,W0ARP-10*:>on the air"))
        XCTAssertTrue(APRSDigestLine.text(for: d).hasSuffix("relayed by W0ARP-10 from another channel"))
    }

    /// A relayed message's thread, ack and reply belong to the station that
    /// wrote it; acking the igate would answer someone who said nothing.
    func testARelayedMessageIsFromItsSource() {
        XCTAssertEqual(PacketEngine.aprsMessageSender(
            info: Data("}YF3CJU-5>APDR16,TCPIP,K5RHD-10*::AK0U-4   :Hello{12".utf8), heardFrom: "K5RHD-10"),
                       "YF3CJU-5")
        XCTAssertEqual(PacketEngine.aprsMessageSender(
            info: Data(":AK0U-4   :Hello{12".utf8), heardFrom: "K5RHD-10"), "K5RHD-10")
    }

    /// An NWS bulletin a local igate relays reads `}WXSVR-x>…`. The alert
    /// gate checked the igate's callsign against the NWS gateway prefixes and
    /// dropped every alert that arrived this way.
    func testARelayedNWSAlertIsKeptAndCredited() throws {
        let alert = try XCTUnwrap(APRSWeatherAlert.classify(
            bulletinID: "1", text: "SEVERE THUNDERSTORM WARNING UNTIL 7PM",
            from: "WXSVR-CO", relayedBy: "w0xyz", heard: Date()))
        XCTAssertEqual(alert.source, "WXSVR-CO")
        XCTAssertEqual(alert.relayedBy, "W0XYZ")
        XCTAssertTrue(alert.provenance().hasPrefix("From WXSVR-CO, relayed onto RF by W0XYZ"), alert.provenance())
        XCTAssertNil(APRSWeatherAlert.classify(bulletinID: "1", text: "SEVERE THUNDERSTORM WARNING",
                                               from: "W0XYZ", heard: Date()),
                     "the igate's own callsign is not an NWS gateway")
    }

    /// A relayed object is placed by its source, so only its source may kill
    /// it; the gateway is recorded beside it.
    func testARelayedObjectBelongsToItsSource() throws {
        let live = try XCTUnwrap(APRSObjectReport.parse(info: Data(";SPOTTER  *161843z3923.61N/10440.49W/note".utf8)))
        let kill = try XCTUnwrap(APRSObjectReport.parse(info: Data(";SPOTTER  _161843z3923.61N/10440.49W/note".utf8)))
        var store = APRSObjectStore()
        store.record(live, from: "KC0ABC", relayedBy: "W3OO-1", at: Date())
        XCTAssertEqual(store.live().first?.reportedBy, "KC0ABC")
        XCTAssertEqual(store.live().first?.relayedBy, "W3OO-1")
        XCTAssertFalse(store.record(kill, from: "W3OO-1", at: Date()), "the gateway does not own it")
        XCTAssertTrue(store.record(kill, from: "KC0ABC", relayedBy: "W3OO-1", at: Date()))
    }
}
