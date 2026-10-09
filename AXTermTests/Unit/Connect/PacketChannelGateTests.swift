import XCTest
@testable import AXTerm

/// Why a connected session can't start on a radio on the APRS channel, and
/// what the operator can do about it (2026-10-09).
final class PacketChannelGateTests: XCTestCase {

    private func radio(aprs: Bool) -> RadioProfile {
        var radio = RadioProfile(id: RadioID(rawValue: "tnc4"), name: "TNC4 Mobilinkd")
        radio.aprsEnabled = aprs
        return radio
    }

    func testARadioOnTheAPRSChannelSaysWhyAndNamesItself() {
        let failure = PacketChannelGate.connectFailure(for: radio(aprs: true))
        XCTAssertEqual(failure?.reason, .radioOnAPRSChannel(RadioID(rawValue: "tnc4")))
        XCTAssertEqual(failure?.detail,
                       "TNC4 Mobilinkd is on the APRS channel, where connected sessions are off. "
                       + "Switch it to Packet to connect.")
    }

    func testAPacketRadioOrNoRadioIsNoObstacle() {
        XCTAssertNil(PacketChannelGate.connectFailure(for: radio(aprs: false)))
        XCTAssertNil(PacketChannelGate.connectFailure(for: nil))
    }

    /// The switch is the radio's Channel setting, nothing else: its beacon
    /// becomes an ID beacon and its packet services come back.
    func testSwitchingToPacketChangesOnlyTheChannel() {
        var aprs = radio(aprs: true)
        PacketChannelGate.switchToPacket(&aprs)
        XCTAssertEqual(RadioChannel.of(aprs), .packet)
        XCTAssertTrue(aprs.runsPacketServices)
    }

    /// A Winlink exchange from that radio fails the same way on every
    /// gateway, so the ladder stops instead of trying the next one.
    func testWinlinkSaysWhyAndTheLadderStops() {
        let text = WinlinkSessionRunner.transportErrorText(
            WinlinkTransportError.radioOnAPRSChannel, liveLinks: [])
        XCTAssertEqual(text, "the radio is on the APRS channel, where connected sessions are off. "
                       + "Switch it to Packet in Settings › Radios")
        XCTAssertFalse(WinlinkExchangeFailureClass.isWorthTryingNextGateway(text))
    }
}
