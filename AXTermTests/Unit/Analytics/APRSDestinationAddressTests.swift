//
//  APRSDestinationAddressTests.swift
//  AXTermTests
//
//  What an AX.25 destination field means when APRS is using it for data.
//

import XCTest
@testable import AXTerm

/// Field capture 2026-09-17: of 187 endpoints heard on a 144.390 radio in a
/// day, 105 were destination pseudo-addresses drawn as stations. Mic-E
/// destinations encode latitude, so a moving station minted a new phantom on
/// every beacon; APRS tocalls name the sending software.
@MainActor
final class APRSDestinationAddressTests: XCTestCase {

    private func packet(from: String, to: String, frameType: FrameType,
                        info: [UInt8]) -> Packet {
        let data = Data(info)
        return Packet(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            from: AX25Address(call: from),
            to: AX25Address(call: to),
            via: [],
            frameType: frameType,
            control: frameType == .ui ? 0x03 : 0x00,
            controlByte1: nil,
            pid: 0xF0,
            info: data,
            rawAx25: data,
            infoText: nil
        )
    }

    /// `` ` `` and `'` are Mic-E. The destination is the sender's latitude.
    func testAMicEDestinationIsACoordinate() {
        for dataType: UInt8 in [0x1C, 0x1D, 0x27, 0x60] {
            let p = packet(from: "K5RHD", to: "SYUPZZ", frameType: .ui,
                           info: [dataType] + Array("q]+l .-/".utf8))
            XCTAssertTrue(APRSDestinationAddress.carriesDataRatherThanAStation(p),
                          "data type 0x\(String(dataType, radix: 16)) is Mic-E")
        }
    }

    /// APDW17 is Direwolf, APZAXT is this app. Neither is a station.
    func testAnAPRSTocallNamesSoftware() {
        for tocall in ["APZAXT", "APDW17", "APMI06", "APN391", "APT314", "APGRWO"] {
            let p = packet(from: "WQ8M-9", to: tocall, frameType: .ui,
                           info: Array("!3933.48N/10447.65W#".utf8))
            XCTAssertTrue(APRSDestinationAddress.carriesDataRatherThanAStation(p), tocall)
        }
    }

    /// The thing that must keep working. NET/ROM aliases ride in UI frames and
    /// their destinations are real addresses.
    func testNetRomAliasesAreStillAddresses() {
        for alias in ["NODES", "DRLNOD", "DRLBBS", "EPINOD", "EVANS", "ID", "BEACON"] {
            let p = packet(from: "K0EPI-7", to: alias, frameType: .ui,
                           info: Array("NODES".utf8))
            XCTAssertFalse(APRSDestinationAddress.carriesDataRatherThanAStation(p), alias)
        }
    }

    /// A connected-mode destination is always a station, whatever it looks like.
    /// This is what keeps a real AP-prefix callsign safe: Pakistan's prefix
    /// makes `AP2ABC` a genuine station, and it is worked in connected mode
    /// rather than named in the destination of somebody's beacon.
    func testAConnectedModeDestinationIsAlwaysAStation() {
        let p = packet(from: "K0EPI", to: "AP2ABC", frameType: .i,
                       info: Array("HELLO".utf8))
        XCTAssertFalse(APRSDestinationAddress.carriesDataRatherThanAStation(p))
    }

    /// An empty info field cannot be Mic-E, and must not crash the check.
    func testAnEmptyFrameIsNotMicE() {
        let p = packet(from: "K0EPI", to: "W0ARP-1", frameType: .ui, info: [])
        XCTAssertFalse(APRSDestinationAddress.carriesDataRatherThanAStation(p))
    }

    /// And the end-to-end claim: a Mic-E beacon contributes no destination
    /// node, so the graph stops growing one station per position report.
    func testAMicEBeaconContributesNoDestinationNode() {
        let p = packet(from: "K5RHD", to: "SYUPZZ", frameType: .ui,
                       info: [0x60] + Array("q]+l .-/".utf8))
        let event = PacketEvent(packet: p)
        XCTAssertEqual(event.from, "K5RHD", "the sender is a real station")
        XCTAssertNil(event.to, "its latitude is not")
    }
}
