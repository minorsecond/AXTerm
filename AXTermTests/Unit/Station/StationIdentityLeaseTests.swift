import XCTest
@testable import AXTerm

/// Preventing a callsign collision before anything is transmitted.
///
/// `StationIdentityMonitor` catches a collision from a frame that has already
/// gone out. These rules catch the case we can see coming — two of the
/// operator's own devices — and stop the unattended half of it.
final class StationIdentityLeaseTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func lease(_ device: String, callsign: String = "K0EPI-7",
                       endpoint: String = "100.77.243.13:8001",
                       at seconds: TimeInterval = 0,
                       duration: TimeInterval = StationIdentityLease.duration) -> StationIdentityLease {
        StationIdentityLease(deviceID: device, deviceName: device.capitalized,
                             callsign: callsign, endpoint: endpoint,
                             at: t(seconds), duration: duration)
    }

    // MARK: - What conflicts

    /// The case this exists for: two devices, one callsign, one TNC.
    func testSameCallsignOnSameTNCIsContested() {
        let own = lease("laptop", at: 60)
        let verdict = StationIdentityLeaseResolver.evaluate(
            own: own, others: [lease("home", at: 0)], at: t(120))

        guard case .contested(let holder) = verdict else {
            return XCTFail("expected contested, got \(verdict)")
        }
        XCTAssertEqual(holder.deviceID, "home")
    }

    /// One callsign on two different TNCs is two stations on two channels —
    /// an HF rig and a VHF rig under one licence. Legitimate, and blocking it
    /// would be wrong.
    func testSameCallsignOnADifferentTNCIsClear() {
        let own = lease("laptop", endpoint: "100.77.243.13:8001")
        let other = lease("home", endpoint: "192.168.3.218:8001")
        XCTAssertEqual(StationIdentityLeaseResolver.evaluate(
            own: own, others: [other], at: t(10)), .clear)
    }

    func testDifferentSSIDsOnOneTNCAreClear() {
        let own = lease("laptop", callsign: "K0EPI-1")
        let other = lease("home", callsign: "K0EPI-7")
        XCTAssertEqual(StationIdentityLeaseResolver.evaluate(
            own: own, others: [other], at: t(10)), .clear)
    }

    /// A device does not contest with itself — reading back its own published
    /// lease must not lock it out.
    func testADeviceDoesNotConflictWithItsOwnLease() {
        let own = lease("laptop", at: 0)
        let echoed = lease("laptop", at: 30)
        XCTAssertEqual(StationIdentityLeaseResolver.evaluate(
            own: own, others: [echoed], at: t(60)), .clear)
    }

    /// A stale lease must not block a device with every right to transmit. An
    /// app that was force-quit cannot lock the operator's other radio out.
    func testAnExpiredLeaseDoesNotContest() {
        let own = lease("laptop", at: 0)
        let stale = lease("home", at: 0, duration: 60)
        XCTAssertEqual(StationIdentityLeaseResolver.evaluate(
            own: own, others: [stale], at: t(600)), .clear)
    }

    /// An unconfigured station has no identity to defend. Treating blanks as
    /// matches would have every fresh install block every other one.
    func testAnUnconfiguredStationNeverContests() {
        let noCall = lease("laptop", callsign: "")
        XCTAssertEqual(StationIdentityLeaseResolver.evaluate(
            own: noCall, others: [lease("home")], at: t(10)), .clear)

        let noEndpoint = lease("laptop", endpoint: "")
        XCTAssertEqual(StationIdentityLeaseResolver.evaluate(
            own: noEndpoint, others: [lease("home")], at: t(10)), .clear)
    }

    func testComparisonIgnoresCaseAndWhitespace() {
        let own = StationIdentityLease(deviceID: "laptop", deviceName: "Laptop",
                                       callsign: " k0epi-7 ", endpoint: " 100.77.243.13:8001 ",
                                       at: t(0))
        XCTAssertTrue(StationIdentityLeaseResolver.evaluate(
            own: own, others: [lease("home")], at: t(10)).isContested)
    }

    /// When several devices contest, the one that got there first is named —
    /// the operator needs to know which device to go and change.
    func testTheOldestHolderIsNamed() {
        let own = lease("tablet", at: 300)
        let verdict = StationIdentityLeaseResolver.evaluate(
            own: own, others: [lease("laptop", at: 120), lease("home", at: 30)], at: t(400))

        guard case .contested(let holder) = verdict else { return XCTFail("expected contested") }
        XCTAssertEqual(holder.deviceID, "home")
    }

    // MARK: - What it does about it

    /// The split that matters. Unattended transmission into a contested
    /// identity must not happen — nobody is watching and both stations reply
    /// to the same caller.
    func testUnattendedTransmissionIsHeldOffWhenContested() {
        let contested = StationIdentityLeaseResolver.Verdict.contested(holder: lease("home"))
        XCTAssertFalse(StationIdentityLeaseResolver.mayTransmitUnattended(contested))
        XCTAssertTrue(StationIdentityLeaseResolver.mayTransmitUnattended(.clear))
    }

    /// The explanation must name the other device, the address, and the fix.
    /// "Contested" on its own tells the operator nothing they can act on.
    func testTheExplanationNamesTheDeviceAndTheFix() {
        let own = lease("laptop")
        let verdict = StationIdentityLeaseResolver.evaluate(
            own: own, others: [lease("home")], at: t(10))
        let text = StationIdentityLeaseResolver.explanation(for: verdict, own: own) ?? ""

        XCTAssertTrue(text.contains("Home"), text)
        XCTAssertTrue(text.contains("K0EPI-7"), text)
        XCTAssertTrue(text.contains("SSID"), text)
        // And it must be honest that a deliberate transmission is still allowed.
        XCTAssertTrue(text.lowercased().contains("deliberately"), text)
    }

    func testAClearVerdictHasNothingToExplain() {
        XCTAssertNil(StationIdentityLeaseResolver.explanation(for: .clear, own: lease("laptop")))
    }

    // MARK: - Timing

    /// Two missed renewals must still leave the lease valid, or an ordinary
    /// sync gap expires a station that is plainly still there.
    func testHeartbeatIntervalLeavesRoomForMissedRenewals() {
        XCTAssertGreaterThanOrEqual(StationIdentityLease.duration,
                                    StationIdentityLease.heartbeatInterval * 3)
    }

    /// And the lease must not outlive its usefulness: a force-quit device
    /// should release the address in minutes, not hours.
    func testLeaseExpiresWithinAReasonableTime() {
        XCTAssertLessThanOrEqual(StationIdentityLease.duration, 30 * 60)
    }
}

/// The P2P listener's refusal to answer into a contested address.
final class WinlinkP2PContestedIdentityTests: XCTestCase {

    private func listener(armed: Bool = true, contestedBy: String? = nil) -> WinlinkP2PListener {
        WinlinkP2PListener(isArmed: armed, myCallsign: "K0EPI-7",
                           isExchangeRunning: false, contestedBy: contestedBy)
    }

    /// An armed station whose callsign is held by another device must not
    /// answer. Both would reply to the same caller, with no operator present
    /// on either.
    func testAnArmedStationDoesNotAnswerWhenTheAddressIsContested() {
        let decision = listener(contestedBy: "Home iMac")
            .decide(called: "K0EPI-7", isInitiator: false)
        XCTAssertEqual(decision, .identityContested(holder: "Home iMac"))
    }

    /// The refusal has to be diagnosable after the fact — a station that
    /// silently ignores callers is indistinguishable from a broken one.
    func testTheRefusalExplainsItself() {
        let decision = WinlinkP2PListener.Decision.identityContested(holder: "Home iMac")
        XCTAssertTrue(decision.explanation.contains("Home iMac"))
        XCTAssertTrue(decision.explanation.lowercased().contains("both reply"))
    }

    func testAnUncontestedStationStillAnswers() {
        XCTAssertEqual(listener().decide(called: "K0EPI-7", isInitiator: false), .answer)
    }

    /// Contest is checked before the callsign match, because a matching call
    /// is exactly the dangerous case: it is ours, and it is also theirs.
    func testContestOutranksTheCallsignMatch() {
        let decision = listener(contestedBy: "Home iMac")
            .decide(called: "K0EPI-7", isInitiator: false)
        guard case .identityContested = decision else {
            return XCTFail("expected contested, got \(decision)")
        }
    }

    /// A station that was never armed is not answering anyway; the contest is
    /// beside the point and "not armed" is the more useful explanation.
    func testNotArmedOutranksContest() {
        XCTAssertEqual(listener(armed: false, contestedBy: "Home iMac")
            .decide(called: "K0EPI-7", isInitiator: false), .notArmed)
    }
}
