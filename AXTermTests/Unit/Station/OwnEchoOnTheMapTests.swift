import XCTest
@testable import AXTerm

/// Which heard addresses are only our own frames coming back.
///
/// A frame we sent, repeated by a digipeater, decodes as a station with our
/// address. It is recognized by content: the same source, destination,
/// control and info as something we transmitted, whatever the via path says
/// (`StationIdentityMonitor.fingerprint`). Position plays no part.
final class OwnEchoOnTheMapTests: XCTestCase {

    private let beacon = Data("!/:KlX4#-@>  ATesting car".utf8)

    private func frame(_ direction: Packet.Direction, from call: String, ssid: Int = 0,
                       to dest: String = "APZAXT", info: Data,
                       via: [AX25Address] = [], at: TimeInterval = 100) -> Packet {
        Packet(timestamp: Date(timeIntervalSince1970: at),
               from: AX25Address(call: call, ssid: ssid), to: AX25Address(call: dest),
               via: via, frameType: .ui, control: 0x03, pid: 0xF0, info: info,
               rawAx25: Data([0x01]), direction: direction)
    }

    private var repeatedByDigi: [AX25Address] {
        [AX25Address(call: "DRLNOD", repeated: true)]
    }

    /// The 2026-09-29 case: we beaconed as K0EPI and a digipeater repeated it.
    func testOurBeaconRepeatedByADigipeaterIsOurs() {
        let packets = [frame(.tx, from: "K0EPI", info: beacon),
                       frame(.rx, from: "K0EPI", info: beacon, via: repeatedByDigi, at: 102)]
        XCTAssertEqual(HeardStationMap.ownEchoAddresses(in: packets), ["K0EPI"])
    }

    /// The 2026-10-09 case: the phone's own beacon as K0EPI-3. We never sent
    /// it, so it is another station even though it is our license.
    func testASiblingSSIDWeNeverSentIsNotOurs() {
        let packets = [frame(.tx, from: "K0EPI", ssid: 2, info: Data("A".utf8)),
                       frame(.rx, from: "K0EPI", ssid: 3, info: beacon)]
        XCTAssertEqual(HeardStationMap.ownEchoAddresses(in: packets), [])
    }

    /// Same address, different content: somebody else using an address we
    /// once transmitted as is somebody else.
    func testAnAddressWeUsedWithDifferentContentIsNotOurs() {
        let packets = [frame(.tx, from: "K0EPI", info: beacon),
                       frame(.rx, from: "K0EPI", info: Data("Another radio".utf8))]
        XCTAssertEqual(HeardStationMap.ownEchoAddresses(in: packets), [])
    }

    /// One of its frames is our echo and another is not: the address is also
    /// in use by another radio, which stays on the map.
    func testAnAddressHeardWithBothOursAndOtherFramesIsNotOurs() {
        let packets = [frame(.tx, from: "K0EPI", info: beacon),
                       frame(.rx, from: "K0EPI", info: beacon, via: repeatedByDigi, at: 102),
                       frame(.rx, from: "K0EPI", info: Data("Another radio".utf8), at: 200)]
        XCTAssertEqual(HeardStationMap.ownEchoAddresses(in: packets), [])
    }

    /// The destination is part of the frame's identity.
    func testTheSameTextToAnotherDestinationIsNotOurs() {
        let packets = [frame(.tx, from: "K0EPI", to: "APZAXT", info: beacon),
                       frame(.rx, from: "K0EPI", to: "BEACON", info: beacon)]
        XCTAssertEqual(HeardStationMap.ownEchoAddresses(in: packets), [])
    }

    func testNothingTransmittedMeansNothingIsOurs() {
        XCTAssertEqual(HeardStationMap.ownEchoAddresses(
            in: [frame(.rx, from: "K0EPI", info: beacon)]), [])
    }
}
