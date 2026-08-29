import XCTest
@testable import AXTerm

/// The validity bridge between the docker rig and the app: the byte
/// strings the Python node farm (TestRig/scripts/netrom.py) puts on the
/// air are pinned here and parsed by AXTerm's REAL NetRomBroadcastParser.
/// If the Python encoder ever drifts from the wire format, this test
/// fails — so "the rig broadcasts NODES" means "NODES AXTerm parses",
/// not "NODES that merely look plausible".
///
/// The hex below is the literal output of
///   python3 -c "from netrom import nodes_payload;
///     print(nodes_payload('DENVER',
///       [('KE0GB',7,'COSCO','KB5YZB',7,192),
///        ('W0ARP',10,'BOULDR','W0ARP',10,140)])[0].hex())"
/// Regenerate it the same way if the farm's format legitimately changes.
final class RigFarmWireCompatibilityTests: XCTestCase {

    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

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
            infoText: nil)
    }

    func testTheFarmsNodesBroadcastParsesInAXTerm() {
        let payload = bytes(
            "ff44454e564552968a608e84406e434f53434f2096846ab2b4846e"
            + "c0ae6082a4a04074424f554c4452ae6082a4a040748c")

        guard let parsed = NetRomBroadcastParser.parse(
            packet: packet(from: AX25Address(call: "W0TX", ssid: 2),
                           payload: payload)) else {
            return XCTFail("the rig's NODES broadcast must parse in AXTerm — "
                           + "if this fails, TestRig/scripts/netrom.py has "
                           + "drifted from the wire format")
        }

        XCTAssertEqual(parsed.entries.count, 2)

        XCTAssertEqual(parsed.entries[0].destinationCallsign, "KE0GB-7")
        XCTAssertEqual(parsed.entries[0].destinationAlias, "COSCO")
        XCTAssertEqual(parsed.entries[0].bestNeighborCallsign, "KB5YZB-7")
        XCTAssertEqual(parsed.entries[0].quality, 192)

        XCTAssertEqual(parsed.entries[1].destinationCallsign, "W0ARP-10")
        XCTAssertEqual(parsed.entries[1].destinationAlias, "BOULDR")
        XCTAssertEqual(parsed.entries[1].bestNeighborCallsign, "W0ARP-10")
        XCTAssertEqual(parsed.entries[1].quality, 140)
    }
}
