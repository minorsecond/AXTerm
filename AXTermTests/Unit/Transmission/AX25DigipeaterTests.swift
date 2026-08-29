import XCTest
@testable import AXTerm

/// Classic L2 digipeating: repeat a frame addressed via us, set our
/// H bit, change nothing else. The loop protection IS the H bit.
final class AX25DigipeaterTests: XCTestCase {

    /// Raw AX.25 address field: six shifted characters + SSID byte.
    private func address(_ call: String, ssid: UInt8 = 0,
                         repeated: Bool = false, last: Bool = false) -> Data {
        var bytes = Data()
        let padded = call.padding(toLength: 6, withPad: " ", startingAt: 0)
        for scalar in padded.unicodeScalars {
            bytes.append(UInt8(scalar.value) << 1)
        }
        var ssidByte: UInt8 = 0x60 | (ssid << 1)
        if repeated { ssidByte |= 0x80 }
        if last { ssidByte |= 0x01 }
        bytes.append(ssidByte)
        return bytes
    }

    private func frame(from src: String, srcSSID: UInt8 = 0,
                       to dst: String,
                       vias: [(call: String, ssid: UInt8, repeated: Bool)]) -> Data {
        var raw = Data()
        raw.append(address(dst))
        raw.append(address(src, ssid: srcSSID, last: vias.isEmpty))
        for (index, via) in vias.enumerated() {
            raw.append(address(via.call, ssid: via.ssid,
                               repeated: via.repeated,
                               last: index == vias.count - 1))
        }
        raw.append(0x03)  // UI
        raw.append(0xF0)
        raw.append(Data("hello".utf8))
        return raw
    }

    func testRepeatsAFrameAddressedViaUsAndOnlySetsOurHBit() {
        let raw = frame(from: "W0ARP", to: "CQ",
                        vias: [("K0EPI", 7, false)])
        let out = AX25Digipeater.repeatFrame(raw, myAddresses: ["K0EPI-7"])
        XCTAssertNotNil(out)
        // Identical except one bit: our SSID byte gains 0x80.
        var expected = raw
        expected[20] |= 0x80
        XCTAssertEqual(out, expected,
                       "a digipeater changes exactly one bit of the frame")
    }

    func testNeverRepeatsTwice() {
        let raw = frame(from: "W0ARP", to: "CQ",
                        vias: [("K0EPI", 7, true)])
        XCTAssertNil(AX25Digipeater.repeatFrame(raw, myAddresses: ["K0EPI-7"]),
                     "our H bit already set — repeating again is the loop")
    }

    func testOnlyTheNextUnrepeatedDigiMayAct() {
        // We are second in line; the first hop has not acted yet.
        let raw = frame(from: "W0ARP", to: "CQ",
                        vias: [("KD0SSP", 7, false), ("K0EPI", 7, false)])
        XCTAssertNil(AX25Digipeater.repeatFrame(raw, myAddresses: ["K0EPI-7"]),
                     "digipeating out of order corrupts the path story")
        // After the first hop acts, it is our turn.
        let advanced = frame(from: "W0ARP", to: "CQ",
                             vias: [("KD0SSP", 7, true), ("K0EPI", 7, false)])
        XCTAssertNotNil(AX25Digipeater.repeatFrame(advanced, myAddresses: ["K0EPI-7"]))
    }

    func testAnAliasAnswersToo() {
        let raw = frame(from: "W0ARP", to: "CQ",
                        vias: [("DWARC", 0, false)])
        XCTAssertNotNil(AX25Digipeater.repeatFrame(
            raw, myAddresses: ["K0EPI-7", "DWARC"]))
    }

    func testOurOwnFramesAndUnrelatedFramesAreLeftAlone() {
        let ours = frame(from: "K0EPI", srcSSID: 7, to: "CQ",
                         vias: [("K0EPI", 7, false)])
        XCTAssertNil(AX25Digipeater.repeatFrame(ours, myAddresses: ["K0EPI-7"]),
                     "repeating our own transmission is an echo chamber")

        let other = frame(from: "W0ARP", to: "CQ",
                          vias: [("KD0SSP", 7, false)])
        XCTAssertNil(AX25Digipeater.repeatFrame(other, myAddresses: ["K0EPI-7"]))

        let direct = frame(from: "W0ARP", to: "CQ", vias: [])
        XCTAssertNil(AX25Digipeater.repeatFrame(direct, myAddresses: ["K0EPI-7"]))
    }

    func testGarbageIsRefusedQuietly() {
        XCTAssertNil(AX25Digipeater.repeatFrame(Data([0x01, 0x02]),
                                                myAddresses: ["K0EPI-7"]))
    }
}
