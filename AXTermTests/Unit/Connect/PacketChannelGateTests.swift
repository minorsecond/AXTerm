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

    // MARK: - On screen, before Connect is pressed

    /// The phone refused the connect but said nothing, and Connect looked
    /// pressable (operator, 2026-10-09). The notice shows in session mode
    /// while not connected, and Connect is disabled while it does.
    func testTheNoticeShowsInSessionModeUntilConnected() {
        let block = PacketChannelGate.connectFailure(for: radio(aprs: true))
        XCTAssertEqual(PacketChannelGate.notice(block: block, mode: .connected, sessionState: nil)?.radio,
                       RadioID(rawValue: "tnc4"))
        XCTAssertEqual(PacketChannelGate.notice(block: block, mode: .connected, sessionState: .disconnected)?.text,
                       block?.detail)
        XCTAssertNil(PacketChannelGate.notice(block: block, mode: .datagram, sessionState: nil),
                     "broadcast mode is APRS's own business")
        XCTAssertNil(PacketChannelGate.notice(block: block, mode: .connected, sessionState: .connected),
                     "a link already open is left alone")
        XCTAssertNil(PacketChannelGate.notice(block: nil, mode: .connected, sessionState: nil))
    }

    /// The notice names the radio, for the question Switch to Packet asks
    /// first (retest 2026-10-10, finding 14).
    func testTheNoticeNamesTheRadioForTheQuestion() {
        let block = PacketChannelGate.connectFailure(for: radio(aprs: true))
        XCTAssertEqual(PacketChannelGate.notice(block: block, mode: .connected, sessionState: nil)?.radioName,
                       "TNC4 Mobilinkd")
    }

    func testConnectIsDisabledWhileTheRadioIsOnAPRS() {
        let block = PacketChannelGate.connectFailure(for: radio(aprs: true))
        XCTAssertTrue(PacketChannelGate.blocksConnect(block, mode: .connected))
        XCTAssertFalse(PacketChannelGate.blocksConnect(nil, mode: .connected))
        XCTAssertFalse(PacketChannelGate.blocksConnect(block, mode: .datagram))
    }
}
