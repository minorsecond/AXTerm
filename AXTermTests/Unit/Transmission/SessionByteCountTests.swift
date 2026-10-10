import XCTest
@testable import AXTerm

/// The session counts the bytes of the frames the peer acknowledges, one
/// frame at a time, and the bytes it sends for the first time. The sender's
/// progress for a long message reads these (retest 2026-10-10, finding 8).
@MainActor
final class SessionByteCountTests: XCTestCase {

    private let peer = AX25Address(call: "K0EPI", ssid: 3)

    private func connected(clock: AX25VirtualClock) -> (AX25SessionManager, AX25Session) {
        let manager = AX25SessionManager(localCallsign: AX25Address(call: "K0EPI", ssid: 2), clock: clock)
        manager.defaultConfig = AX25SessionConfig(windowSize: 1, paclen: 128, rtoMin: 1, rtoMax: 16, initialRto: 2,
                                                  maxWindowSize: 4, maxPaclen: 256)
        _ = manager.connect(to: peer, path: DigiPath(), radio: .primary)
        manager.handleInboundUA(from: peer, path: DigiPath(), radio: .primary)
        return (manager, manager.session(for: peer, path: DigiPath(), radio: .primary))
    }

    func testAcknowledgedBytesFollowTheFramesWhateverTheirSize() {
        let clock = AX25VirtualClock()
        let (manager, session) = connected(clock: clock)
        _ = manager.sendData(Data(repeating: 0x41, count: 300), to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.bytesAcknowledged, 0)

        // Raised before the first RR, so the frame that RR lets out is cut
        // at 256: the other 172 bytes in one frame.
        manager.updateLinkTargets(for: session, window: 1, paclen: 256, reason: "test")
        manager.handleInboundRR(from: peer, path: DigiPath(), radio: .primary, nr: session.vs)
        XCTAssertEqual(session.bytesAcknowledged, 128)
        manager.handleInboundRR(from: peer, path: DigiPath(), radio: .primary, nr: session.vs)
        XCTAssertEqual(session.bytesAcknowledged, 300, "the second frame carried the other 172")
    }

    func testARetransmissionIsNotCountedAgain() {
        let clock = AX25VirtualClock()
        let (manager, session) = connected(clock: clock)
        _ = manager.sendData(Data(repeating: 0x41, count: 100), to: peer, path: DigiPath(), radio: .primary)
        XCTAssertEqual(session.statistics.bytesSent, 100)
        _ = manager.handleT1Timeout(session: session)
        XCTAssertEqual(session.statistics.bytesSent, 100)
        manager.handleInboundRR(from: peer, path: DigiPath(), radio: .primary, nr: session.vs)
        XCTAssertEqual(session.bytesAcknowledged, 100)
    }
}
