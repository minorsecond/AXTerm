import XCTest
@testable import AXTerm

/// When the app holds off sleep, and when it merely refuses to be throttled.
///
/// On iOS a sleeping display is the first step toward the app being suspended,
/// and a suspended app loses its TCP connection to the TNC. On macOS the app
/// is not suspended, it is napped — which is what took this station off the
/// air for eight hours on 2026-09-18 with the Mac awake the whole time.
///
/// Both cost something real, so the rules are worth pinning rather than left
/// to a boolean somebody flips later.
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
    func testAnArmedListenerHoldsOffSleep() {
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

    /// The indicator says *why* sleep is being held off, because a bare "held
    /// on" reads as a bug rather than a decision.
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

    // MARK: - The two holds

    /// Nothing live, nothing asked for. An idle AXTerm has no business pinning
    /// a machine's scheduler, let alone its power state.
    func testAnIdleStationAsksForNothing() {
        for policy in KeepAwakePolicy.allCases {
            XCTAssertEqual(
                KeepAwakeController.hold(policy: policy, isConnected: false,
                                         isTransferring: false, isListening: false),
                .none, policy.rawValue)
        }
    }

    /// The weaker hold is not a preference. An app carrying open radio links
    /// should never be napped whatever the policy says: it costs the operator
    /// nothing and it does not keep the machine awake.
    ///
    /// This is the one that would have saved 2026-09-18. The Mac stayed awake
    /// all night — every policy would have been satisfied — and the links died
    /// anyway, because App Nap coalesced the timers that fed them.
    func testStayingScheduledIsNotTheOperatorsChoice() {
        XCTAssertEqual(
            KeepAwakeController.hold(policy: .never, isConnected: true,
                                     isTransferring: false, isListening: false),
            .scheduling,
            "'never' is about sleep; it does not ask to be throttled")

        XCTAssertEqual(
            KeepAwakeController.hold(policy: .duringTransfers, isConnected: true,
                                     isTransferring: false, isListening: false),
            .scheduling)
    }

    /// The stronger hold is, and it follows the same table the policy always
    /// had.
    func testHoldingOffSleepFollowsThePolicy() {
        XCTAssertEqual(
            KeepAwakeController.hold(policy: .whileConnected, isConnected: true,
                                     isTransferring: false, isListening: false),
            .schedulingAndAwake)

        XCTAssertEqual(
            KeepAwakeController.hold(policy: .duringTransfers, isConnected: true,
                                     isTransferring: true, isListening: false),
            .schedulingAndAwake)
    }

    /// A transfer with no link is still something to protect — it is about to
    /// need one — and it is certainly not nothing.
    func testATransferWithoutAConnectionStillCounts() {
        XCTAssertNotEqual(
            KeepAwakeController.hold(policy: .duringTransfers, isConnected: false,
                                     isTransferring: true, isListening: false),
            .none)
    }

    // MARK: - Platform

    /// Offered everywhere now. It was withheld on macOS on the theory that a
    /// Mac's display sleeping does not drop its sockets. The night of
    /// 2026-09-18 disproved that: the display slept at 19:50, App Nap
    /// throttled the app, both links died, and the station was off the air
    /// until 03:54 — with the Mac awake the whole time.
    func testTheSettingIsOfferedOnEveryPlatform() {
        XCTAssertTrue(KeepAwakeController.isSupported)
    }

    func testThePolicyRoundTripsThroughItsRawValue() {
        for policy in KeepAwakePolicy.allCases {
            XCTAssertEqual(KeepAwakePolicy(rawValue: policy.rawValue), policy)
        }
    }
}

/// The controller's own bookkeeping.
///
/// A fresh instance rather than `.shared`, so nothing here touches the real
/// process's power assertions or leaks state into another test.
@MainActor
final class KeepAwakeControllerTests: XCTestCase {

    func testAFreshControllerHoldsNothing() {
        let c = KeepAwakeController()
        XCTAssertEqual(c.hold, .none)
        XCTAssertFalse(c.isHoldingAwake)
        XCTAssertNil(c.reason)
    }

    /// A radio coming up is enough on its own. The other two inputs are
    /// remembered, which is what lets a station whose window has been closed
    /// still get its hold right.
    func testALinkComingUpIsEnoughToChangeTheHold() {
        let c = KeepAwakeController()
        c.policy = .whileConnected

        c.connectionChanged(isConnected: true)
        XCTAssertEqual(c.hold, .schedulingAndAwake)

        c.connectionChanged(isConnected: false)
        XCTAssertEqual(c.hold, .none)
    }

    /// Changing the setting re-applies without anyone having to say what the
    /// station is doing again.
    func testChangingThePolicyReappliesOnItsOwn() {
        let c = KeepAwakeController()
        c.update(policy: .never, isConnected: true,
                 isTransferring: false, isListening: false)
        XCTAssertEqual(c.hold, .scheduling, "never is about sleep, not throttling")

        c.policy = .whileConnected
        XCTAssertEqual(c.hold, .schedulingAndAwake)
    }

    /// Releasing drops everything, which is what happens on the way into a
    /// sleep: an assertion outliving the thing it was protecting is a leak.
    func testReleasingDropsEverything() {
        let c = KeepAwakeController()
        c.update(policy: .whileConnected, isConnected: true,
                 isTransferring: false, isListening: false)
        XCTAssertEqual(c.hold, .schedulingAndAwake)

        c.release()
        XCTAssertEqual(c.hold, .none)
        XCTAssertFalse(c.isHoldingAwake)
        XCTAssertNil(c.reason)
    }

    /// The indicator is for the hold the operator chose. Staying scheduled is
    /// invisible and should be — it is not a decision they made.
    func testStayingScheduledShowsNoIndicator() {
        let c = KeepAwakeController()
        c.update(policy: .duringTransfers, isConnected: true,
                 isTransferring: false, isListening: false)
        XCTAssertEqual(c.hold, .scheduling)
        XCTAssertFalse(c.isHoldingAwake)
        XCTAssertNil(c.reason)
    }
}
