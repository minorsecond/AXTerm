import XCTest
@testable import AXTerm

/// When the app holds the screen on.
///
/// On iOS this is not a convenience: a sleeping display is the first step
/// toward the app being suspended, and a suspended app loses its TCP
/// connection to the TNC. It is also a battery cost on a device that may be
/// the operator's only light at the end of an activation, so the rules are
/// worth pinning rather than left to a boolean somebody flips later.
final class KeepAwakePolicyTests: XCTestCase {

    private func holds(_ policy: KeepAwakePolicy,
                       connected: Bool = false,
                       transferring: Bool = false,
                       listening: Bool = false) -> Bool {
        policy.shouldHoldAwake(isConnected: connected,
                               isTransferring: transferring,
                               isListening: listening)
    }

    // MARK: - The default

    /// The default protects what would actually break — a transfer in flight
    /// — and nothing else.
    func testDuringTransfersHoldsOnlyWhileSomethingIsRunning() {
        XCTAssertTrue(holds(.duringTransfers, connected: true, transferring: true))
        XCTAssertFalse(holds(.duringTransfers, connected: true))
        XCTAssertFalse(holds(.duringTransfers))
    }

    /// An armed peer-to-peer listener counts. A station that sleeps stops
    /// answering calls, and nobody finds out until somebody fails to reach
    /// it — which is the worst way for this to fail.
    func testAnArmedListenerHoldsTheScreen() {
        XCTAssertTrue(holds(.duringTransfers, connected: true, listening: true))
    }

    // MARK: - The other two

    func testWhileConnectedHoldsForAnyLiveConnection() {
        XCTAssertTrue(holds(.whileConnected, connected: true))
        XCTAssertFalse(holds(.whileConnected), "nothing to hold when disconnected")
    }

    /// Never means never, whatever is going on. An operator who has chosen to
    /// let the device sleep has accepted the consequence, and overriding that
    /// during a transfer would be the app deciding it knows better.
    func testNeverHoldsUnderAnyCondition() {
        XCTAssertFalse(holds(.never, connected: true, transferring: true, listening: true))
    }

    // MARK: - Explaining

    /// Every option has a real cost or a real consequence, and the operator
    /// is choosing between them — so each says which.
    func testEveryPolicyExplainsItsTradeoff() {
        for policy in KeepAwakePolicy.allCases {
            XCTAssertFalse(policy.title.isEmpty, policy.rawValue)
            XCTAssertGreaterThan(policy.detail.count, 60, policy.rawValue)
        }
        // The two that matter most name their actual consequence.
        XCTAssertTrue(KeepAwakePolicy.never.detail.lowercased().contains("interrupted"))
        XCTAssertTrue(KeepAwakePolicy.whileConnected.detail.lowercased().contains("battery"))
    }

    /// The indicator says *why* the screen is being held, because "screen
    /// stays on" on its own reads as a bug rather than a decision.
    func testTheReasonNamesTheCause() {
        XCTAssertTrue(KeepAwakeController.reasonText(
            isTransferring: true, isListening: false, isConnected: true)
            .lowercased().contains("transfer"))

        XCTAssertTrue(KeepAwakeController.reasonText(
            isTransferring: false, isListening: true, isConnected: true)
            .lowercased().contains("answer"))

        XCTAssertTrue(KeepAwakeController.reasonText(
            isTransferring: false, isListening: false, isConnected: true)
            .lowercased().contains("battery"))
    }

    /// A transfer outranks a listener in the message: both may be true, and
    /// the transfer is the one with something to lose right now.
    func testATransferIsReportedAheadOfAListener() {
        let text = KeepAwakeController.reasonText(
            isTransferring: true, isListening: true, isConnected: true)
        XCTAssertTrue(text.lowercased().contains("transfer"), text)
    }

    // MARK: - Platform

    /// Not offered on macOS: a Mac's display sleeping does not suspend the
    /// app or drop its sockets, so there is nothing to configure.
    func testTheSettingIsOnlyOfferedWhereItMeansSomething() {
        #if os(macOS)
        XCTAssertFalse(KeepAwakeController.isSupported)
        #else
        XCTAssertTrue(KeepAwakeController.isSupported)
        #endif
    }

    func testThePolicyRoundTripsThroughItsRawValue() {
        for policy in KeepAwakePolicy.allCases {
            XCTAssertEqual(KeepAwakePolicy(rawValue: policy.rawValue), policy)
        }
    }
}
