import XCTest
@testable import AXTerm

/// How long a TNC4 connect waits, and when reconnecting stops.
///
/// CoreBluetooth's connect never times out. At the home retest (2026-10-10)
/// the iPad sat on "connecting" with no explanation while the iPhone held the
/// TNC4, and the iPhone's own reconnect had been pending since 17:20:52Z: it
/// took the TNC4 at 18:39:20Z, five seconds after the iPad let it go.
final class BLEConnectPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    /// A connect the operator started stops, and says why.
    func testAnUnansweredConnectGivesUpWithAReason() {
        guard case .giveUp(let message) = BLEConnectPolicy.afterUnansweredConnect(
            reconnectingSince: nil, attempt: 1, now: t0) else {
            return XCTFail("expected to give up")
        }
        XCTAssertTrue(message.contains("isn't answering"), message)
        XCTAssertTrue(message.contains("another device"), message)
    }

    /// After a drop, keep trying for a while, backing off.
    func testAReconnectKeepsTryingWithinTheWindow() {
        XCTAssertEqual(BLEConnectPolicy.afterUnansweredConnect(
            reconnectingSince: t0, attempt: 1, now: t0.addingTimeInterval(20)), .retry(after: 1))
        XCTAssertEqual(BLEConnectPolicy.afterUnansweredConnect(
            reconnectingSince: t0, attempt: 3, now: t0.addingTimeInterval(90)), .retry(after: 4))
        XCTAssertEqual(BLEConnectPolicy.afterUnansweredConnect(
            reconnectingSince: t0, attempt: 9, now: t0.addingTimeInterval(250)), .retry(after: 30))
    }

    /// And then stop, rather than wait as long as it takes.
    func testAReconnectGivesUpAfterTheWindow() {
        guard case .giveUp(let message) = BLEConnectPolicy.afterUnansweredConnect(
            reconnectingSince: t0, attempt: 12, now: t0.addingTimeInterval(BLEConnectPolicy.reconnectWindow + 1)) else {
            return XCTFail("expected to give up")
        }
        XCTAssertTrue(message.contains("Stopped trying to reconnect"), message)
    }

    /// Long enough for a TNC4 that is slow to wake, short enough not to look
    /// stuck.
    func testTheConnectTimeout() {
        XCTAssertGreaterThanOrEqual(BLEConnectPolicy.connectTimeout, 10)
        XCTAssertLessThanOrEqual(BLEConnectPolicy.connectTimeout, 30)
        XCTAssertEqual(BLEConnectPolicy.reconnectWindow, 5 * 60)
    }
}
