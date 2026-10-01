import XCTest
@testable import AXTerm

/// A UI frame built without an explicit control byte, heard straight back, is
/// our own echo.
///
/// Field capture 2026-10-01 16:33:12 UTC: Station A sent the AXDP text probe
/// (`AXDP?\r`, a UI frame) to K0EPI-3, heard it back two seconds later
/// through the IC-705, and reported "Another station is transmitting as
/// K0EPI-2". The probe is built as a bare `OutboundFrame` with no control
/// byte. The encoder puts 0x03 on the air for that, but the echo memory
/// recorded 0, so the copy that came back matched nothing we had sent.
final class OwnUIEchoTests: XCTestCase {

    private let me = AX25Address(call: "K0EPI", ssid: 2)
    private let peer = AX25Address(call: "K0EPI", ssid: 3)

    /// Built the way `SessionCoordinator.transmitTextProbe` builds it.
    private func probe() -> OutboundFrame {
        OutboundFrame(
            destination: peer,
            source: me,
            path: DigiPath(),
            payload: Data("AXDP?\r".utf8),
            frameType: "ui",
            pid: 0xF0,
            displayInfo: "AXDP probe")
    }

    func testAFrameWithNoControlByteGoesOutAsUI() throws {
        let frame = probe()
        XCTAssertNil(frame.controlByte)
        XCTAssertEqual(frame.wireControlByte, AX25Control.ui)
        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: frame.encodeAX25()))
        XCTAssertEqual(decoded.control, frame.wireControlByte,
                       "the control byte remembered is the one on the air")
    }

    func testOurOwnProbeHeardBackIsAnEchoNotACollision() throws {
        let monitor = StationIdentityMonitor()
        let frame = probe()

        // Exactly what PacketEngine.send records.
        monitor.recordTransmitted(
            source: frame.source.display,
            destination: frame.destination.display,
            control: frame.wireControlByte,
            info: frame.payload)

        let decoded = try XCTUnwrap(AX25.decodeFrame(ax25: frame.encodeAX25()))

        // Exactly what PacketEngine does on receive.
        let verdict = monitor.classifyReceived(
            source: decoded.from?.display,
            destination: decoded.to?.display,
            control: decoded.control,
            info: decoded.info,
            ownCallsigns: [me.display],
            frameType: decoded.frameType.rawValue,
            viaRepeated: decoded.via.contains { $0.repeated })

        XCTAssertEqual(verdict, .ownEcho)
    }

    func testAnExplicitControlByteIsKept() {
        let frame = AX25FrameBuilder.buildSABM(from: me, to: peer)
        XCTAssertEqual(frame.wireControlByte, frame.controlByte)
    }
}
