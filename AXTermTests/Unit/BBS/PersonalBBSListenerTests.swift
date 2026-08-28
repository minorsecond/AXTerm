import XCTest
@testable import AXTerm

/// Whether an inbound call gets a mailbox prompt.
///
/// Split between answering the calls that are ours and refusing — legibly —
/// every call that is not. A refusal with no explanation is the same failure
/// as no mailbox at all, so each one is asserted to say what to do about it.
final class PersonalBBSListenerTests: XCTestCase {

    private func listener(armed: Bool = true,
                          winlink: String? = nil,
                          callsign: String = "K0EPI-2",
                          contestedBy: String? = nil,
                          currentCaller: String? = nil) -> PersonalBBSListener {
        PersonalBBSListener(isArmed: armed, winlinkP2PAddress: winlink,
                            myCallsign: callsign, contestedBy: contestedBy,
                            currentCaller: currentCaller)
    }

    // MARK: - Answering

    func testAnswersACallToOurCallsign() {
        XCTAssertEqual(listener().decide(called: "K0EPI-2", isInitiator: false), .answer)
    }

    func testMatchIgnoresCaseAndWhitespace() {
        XCTAssertEqual(listener().decide(called: " k0epi-2 ", isInitiator: false), .answer)
    }

    /// Someone who configured the mailbox as a bare callsign meant "me",
    /// whichever SSID the caller happened to use.
    func testBareCallsignAnswersOnAnySSID() {
        let sut = listener(callsign: "K0EPI")
        XCTAssertEqual(sut.decide(called: "K0EPI-2", isInitiator: false), .answer)
        XCTAssertEqual(sut.decide(called: "K0EPI", isInitiator: false), .answer)
    }

    /// But an explicit SSID is a promise not to answer for the node next door.
    func testExplicitSSIDAnswersOnlyThatSSID() {
        let sut = listener(callsign: "K0EPI-2")
        guard case .wrongCallsign = sut.decide(called: "K0EPI-7", isInitiator: false) else {
            return XCTFail("K0EPI-2 must not answer for K0EPI-7")
        }
    }

    // MARK: - Refusing

    func testOffByDefault() {
        XCTAssertEqual(listener(armed: false).decide(called: "K0EPI-2", isInitiator: false),
                       .notArmed)
    }

    func testOutboundCallsAreNotMailboxSessions() {
        XCTAssertEqual(listener().decide(called: "K0EPI-2", isInitiator: true), .weInitiated)
    }

    // MARK: - Sharing a radio with Winlink P2P

    /// The point of the whole arrangement: Winlink P2P and a mailbox are
    /// different services, and one radio runs both by giving each its own
    /// callsign — exactly how packet radio has always separated services.
    func testWinlinkOnAnotherSSIDDoesNotStopTheMailbox() {
        XCTAssertEqual(
            listener(winlink: "K0EPI-7", callsign: "K0EPI-2")
                .decide(called: "K0EPI-2", isInitiator: false),
            .answer)
    }

    /// They collide only when both answer the address that was dialed. The
    /// answering station speaks first in both protocols, so nothing can tell
    /// what the caller wanted.
    func testSameAddressAsWinlinkIsRefused() {
        XCTAssertEqual(
            listener(winlink: "K0EPI-7", callsign: "K0EPI-7")
                .decide(called: "K0EPI-7", isInitiator: false),
            .addressSharedWithWinlink(address: "K0EPI-7"))
    }

    /// A bare Winlink callsign answers every SSID of itself, so it swallows
    /// the mailbox's SSID too.
    func testBareWinlinkCallsignCollidesWithEverySSID() {
        XCTAssertEqual(
            listener(winlink: "K0EPI", callsign: "K0EPI-2")
                .decide(called: "K0EPI-2", isInitiator: false),
            .addressSharedWithWinlink(address: "K0EPI"))
    }

    func testWinlinkThatIsNotArmedIsNotAConflict() {
        XCTAssertEqual(
            listener(winlink: nil, callsign: "K0EPI-7")
                .decide(called: "K0EPI-7", isInitiator: false),
            .answer)
    }

    /// Checked after the callsign match: a call for somebody else should say
    /// so, not blame Winlink for a conflict that is not why it went unanswered.
    func testCallForAnotherStationIsNotBlamedOnWinlink() {
        guard case .wrongCallsign = listener(winlink: "K0EPI-7", callsign: "K0EPI-2")
            .decide(called: "W0ARP-10", isInitiator: false) else {
            return XCTFail("expected wrongCallsign")
        }
    }

    // MARK: - Address matching

    func testAnswersMatchesBareAndExactCallsigns() {
        XCTAssertTrue(PersonalBBSListener.answers("K0EPI-2", as: "K0EPI"))
        XCTAssertTrue(PersonalBBSListener.answers("K0EPI", as: "K0EPI"))
        XCTAssertTrue(PersonalBBSListener.answers("K0EPI-7", as: "K0EPI-7"))
        XCTAssertFalse(PersonalBBSListener.answers("K0EPI-2", as: "K0EPI-7"))
        // A callsign that merely starts with ours is a different station.
        XCTAssertFalse(PersonalBBSListener.answers("K0EPIA", as: "K0EPI"))
    }

    /// An unconfigured station answers nothing, rather than everything.
    func testEmptyConfigurationAnswersNothing() {
        XCTAssertFalse(PersonalBBSListener.answers("K0EPI-2", as: ""))
    }

    func testCallToAnotherStationIsIgnored() {
        XCTAssertEqual(listener().decide(called: "W0ARP-10", isInitiator: false),
                       .wrongCallsign(called: "W0ARP-10", expected: "K0EPI-2"))
    }

    func testSecondCallerIsRefusedWhileOneIsBeingServed() {
        XCTAssertEqual(listener(currentCaller: "W0ARP").decide(called: "K0EPI-2", isInitiator: false),
                       .busy(caller: "W0ARP"))
    }

    /// Checked before the callsign match: if another device already answers as
    /// this callsign, a *matching* call is exactly the problem.
    func testContestedIdentityIsCheckedBeforeTheCallsignMatches() {
        XCTAssertEqual(
            listener(contestedBy: "MacBook").decide(called: "K0EPI-2", isInitiator: false),
            .identityContested(holder: "MacBook"))
    }

    func testArmingIsCheckedBeforeIdentityContention() {
        // An operator who has not armed the mailbox should be told that, not
        // told about a device conflict that does not matter yet.
        XCTAssertEqual(
            listener(armed: false, contestedBy: "MacBook")
                .decide(called: "K0EPI-2", isInitiator: false),
            .notArmed)
    }

    // MARK: - Explanations

    func testEveryRefusalExplainsItself() {
        let decisions: [PersonalBBSListener.Decision] = [
            .notArmed, .addressSharedWithWinlink(address: "K0EPI-7"),
            .identityContested(holder: "MacBook"),
            .wrongCallsign(called: "W0ARP", expected: "K0EPI-2"), .busy(caller: "W0ARP")
        ]
        for decision in decisions {
            XCTAssertFalse(decision.explanation.isEmpty, "\(decision) has no explanation")
        }
    }

    /// The refusal an operator is most likely to hit names the setting that
    /// fixes it — "ignored" alone costs them the afternoon.
    func testNotArmedNamesTheSetting() {
        XCTAssertTrue(PersonalBBSListener.Decision.notArmed.explanation.contains("Settings"))
    }

    /// The refusal names the fix, not just the problem: the operator loses the
    /// afternoon otherwise.
    func testWinlinkRefusalNamesTheFix() {
        let explanation = PersonalBBSListener.Decision
            .addressSharedWithWinlink(address: "K0EPI-7").explanation
        XCTAssertTrue(explanation.contains("K0EPI-7"))
        XCTAssertTrue(explanation.contains("SSID"))
        XCTAssertTrue(explanation.contains("both can run at once"))
    }
}
