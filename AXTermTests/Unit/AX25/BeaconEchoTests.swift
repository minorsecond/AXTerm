import XCTest
@testable import AXTerm

/// A beacon sent through a digipeater comes straight back, and the station
/// that hears it is us.
///
/// Field capture 2026-08-27: a beacon went out via DRLNOD at 20:14:11, was
/// repeated at 20:14:13, and AXTerm reported "Another station is
/// transmitting as K0EPI-7". Nothing was wrong on the air — it was our own
/// frame, doing exactly what a digipeated frame does.
///
/// Reproduced through the real builder, encoder and decoder rather than by
/// hand-writing the values, because the bug is in what those disagree
/// about, and a test that asserts my guess would pass while the app failed.
final class BeaconEchoTests: XCTestCase {

    private let me = AX25Address(call: "K0EPI", ssid: 7)
    private let beaconText = "K0EPI AXTerm Packet Station | DM79po"

    /// Flip the has-been-repeated bit on the first digipeater, which is the
    /// one thing a digipeater changes.
    private func repeated(_ frame: Data) -> Data {
        var bytes = frame
        // dest(7) + source(7) + first digi(7); the SSID byte is the last of
        // the seven, and H is its top bit.
        let ssidIndex = 7 + 7 + 6
        guard bytes.count > ssidIndex else { return bytes }
        bytes[ssidIndex] |= 0x80
        return bytes
    }

    func testOurOwnDigipeatedBeaconIsNotACollision() throws {
        let monitor = StationIdentityMonitor()
        let frame = AX25FrameBuilder.buildUI(
            from: me,
            to: AX25Address(call: BeaconPlan.destinationCall, ssid: 0),
            via: DigiPath.from(["DRLNOD"]),
            pid: 0xF0,
            payload: Data(beaconText.utf8),
            displayInfo: beaconText)

        // Exactly what PacketEngine.send records.
        monitor.recordTransmitted(
            source: frame.source.display,
            destination: frame.destination.display,
            control: frame.controlByte ?? 0,
            info: frame.payload)

        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: repeated(frame.encodeAX25())))

        // Exactly what PacketEngine does on receive.
        let collision = monitor.inspectReceived(
            source: decoded.from?.display,
            destination: decoded.to?.display,
            control: decoded.control,
            info: decoded.info,
            ownCallsign: me.display,
            frameType: decoded.frameType.rawValue)

        XCTAssertNil(collision,
                     "our own beacon, repeated by a digipeater, is not another station")
    }

    /// The same frame from somebody else really is a collision, or the
    /// suppression above would have disabled the warning entirely.
    func testAnotherStationUsingOurCallsignStillReports() throws {
        let monitor = StationIdentityMonitor()
        let frame = AX25FrameBuilder.buildUI(
            from: me,
            to: AX25Address(call: BeaconPlan.destinationCall, ssid: 0),
            via: DigiPath.from(["DRLNOD"]),
            pid: 0xF0,
            payload: Data("something we never sent".utf8))
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: repeated(frame.encodeAX25())))

        XCTAssertNotNil(monitor.inspectReceived(
            source: decoded.from?.display,
            destination: decoded.to?.display,
            control: decoded.control,
            info: decoded.info,
            ownCallsign: me.display,
            frameType: decoded.frameType.rawValue))
    }

    /// Direct, no digipeater: the TNC does not loop back, but a hearing
    /// station might repeat us some other way.
    func testADirectEchoIsAlsoOurs() throws {
        let monitor = StationIdentityMonitor()
        let frame = AX25FrameBuilder.buildUI(
            from: me,
            to: AX25Address(call: BeaconPlan.destinationCall, ssid: 0),
            pid: 0xF0,
            payload: Data(beaconText.utf8))
        monitor.recordTransmitted(
            source: frame.source.display,
            destination: frame.destination.display,
            control: frame.controlByte ?? 0,
            info: frame.payload)
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: frame.encodeAX25()))

        XCTAssertNil(monitor.inspectReceived(
            source: decoded.from?.display,
            destination: decoded.to?.display,
            control: decoded.control,
            info: decoded.info,
            ownCallsign: me.display,
            frameType: decoded.frameType.rawValue))
    }
}
