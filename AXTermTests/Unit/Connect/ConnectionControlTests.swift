import XCTest
@testable import AXTerm

/// The Connect button in Connection settings.
///
/// This is the only way to open the link on iOS — every other connect action
/// lives in the macOS menu bar or main-window toolbar — so its states are
/// worth pinning rather than left to a boolean read off a live socket.
final class ConnectionControlTests: XCTestCase {

    func testAnIdleLinkOffersToConnect() {
        XCTAssertTrue(ConnectionTransportViewModel.canConnect(from: .disconnected))
    }

    /// A failed attempt is exactly when the operator wants to retry. Showing
    /// "Disconnect" there would strand them with no way back.
    func testAFailedLinkOffersToRetry() {
        XCTAssertTrue(ConnectionTransportViewModel.canConnect(from: .failed))
    }

    func testALiveLinkOffersToDisconnect() {
        XCTAssertFalse(ConnectionTransportViewModel.canConnect(from: .connected))
    }

    /// Mid-attempt the button neither connects nor disconnects — it is
    /// disabled and says "Connecting…", because a second attempt on top of
    /// the first tears down the socket the first one is still opening.
    func testAnAttemptInFlightOffersNeither() {
        XCTAssertFalse(ConnectionTransportViewModel.canConnect(from: .connecting))
    }

    /// Every status resolves to a definite answer: a new case added later
    /// must be classified deliberately rather than defaulting to "connect"
    /// and offering a second attempt on a live link.
    func testEveryStatusIsClassified() {
        for status in [ConnectionStatus.disconnected, .connecting, .connected, .failed] {
            let connectable = ConnectionTransportViewModel.canConnect(from: status)
            XCTAssertEqual(connectable, status == .disconnected || status == .failed,
                           "\(status.rawValue) is classified inconsistently")
        }
    }
}
