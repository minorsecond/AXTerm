import XCTest
@testable import AXTerm

/// What may cross between devices, and what a merge does when it gets there.
final class WinlinkSyncPolicyTests: XCTestCase {

    func testMailAndOperatorKnowledgeSync() {
        for kind in [WinlinkSyncPolicy.Kind.message, .messageState, .contact,
                     .catalogFavorite, .callsignDirectory, .nodeAlias, .stationLease,
                     .callsignBase, .operatorProfile] {
            guard case .synced = WinlinkSyncPolicy.disposition(for: kind) else {
                return XCTFail("\(kind.rawValue) should sync")
            }
        }
    }

    /// The point of the policy: anything measured from one antenna at one
    /// place must not be presented to another device as if it were true
    /// there. A home rig's digipeater path is wrong for a handheld, and a
    /// link measurement taken across town predicts nothing here.
    func testRadioAndPlaceSpecificStateNeverLeavesTheDevice() {
        for kind in [WinlinkSyncPolicy.Kind.stationPreferences, .gatewayLadder,
                     .sessionLog, .gridSquare, .callsignSSID] {
            guard case .deviceLocal = WinlinkSyncPolicy.disposition(for: kind) else {
                return XCTFail("\(kind.rawValue) describes this radio and must stay local")
            }
        }
    }

    /// The lease is the one piece of device-specific state that must travel.
    /// It describes this radio, but its entire purpose is to be read by the
    /// operator's other devices — a claim nobody else can see prevents
    /// nothing. Asserted explicitly so a future tidy-up of "device-local
    /// things do not sync" cannot quietly disable collision prevention.
    func testTheStationLeaseSyncsDespiteDescribingThisDevice() {
        guard case .synced(let why) = WinlinkSyncPolicy.disposition(for: .stationLease) else {
            return XCTFail("the lease must reach other devices to be useful")
        }
        XCTAssertTrue(why.contains("collide"), why)
    }

    /// The callsign splits across the boundary, and that split is the whole
    /// reason a second device sets itself up correctly: the licence travels,
    /// the station address does not. Asserted together so nobody can later
    /// "simplify" them into one setting.
    func testTheCallsignBaseSyncsButTheSSIDDoesNot() {
        guard case .synced = WinlinkSyncPolicy.disposition(for: .callsignBase) else {
            return XCTFail("a licence callsign is the same on every radio")
        }
        guard case .deviceLocal(let why) = WinlinkSyncPolicy.disposition(for: .callsignSSID) else {
            return XCTFail("copying an SSID puts two stations on one address")
        }
        XCTAssertTrue(why.contains("AX.25"), why)
    }

    func testPartialBodyIsTiedToTheSessionThatStartedIt() {
        guard case .sessionLocal = WinlinkSyncPolicy.disposition(for: .partialInboundBody) else {
            return XCTFail("a half-received body belongs to one in-flight session")
        }
    }

    /// Every kind must be classified deliberately. A new kind of persisted
    /// state that nobody classified would otherwise default to whatever the
    /// transport happens to do with it.
    func testEveryKindHasAReason() {
        for kind in WinlinkSyncPolicy.Kind.allCases {
            XCTAssertFalse(WinlinkSyncPolicy.reason(for: kind).isEmpty, kind.rawValue)
        }
    }

    func testSyncedKindsAreExactlyTheSyncedDispositions() {
        XCTAssertEqual(Set(WinlinkSyncPolicy.syncedKinds.map(\.rawValue)),
                       ["message", "messageState", "contact", "catalogFavorite",
                        "callsignDirectory", "nodeAlias", "stationLease",
                        "callsignBase", "operatorProfile"])
    }
}

final class WinlinkStateMergeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func state(_ mid: String = "MID000000001",
                       isRead: Bool = false,
                       folder: Int64 = 1,
                       delivery: WinlinkMessageStateRecord.DeliveryState = .received,
                       at seconds: TimeInterval = 0,
                       error: String? = nil,
                       claim: WinlinkTransmitClaim? = nil,
                       offset: Int = 0,
                       offsetDevice: String? = nil) -> WinlinkStateMerge.State {
        WinlinkStateMerge.State(mid: mid, isRead: isRead, folderId: folder,
                                deliveryState: delivery, updatedAt: t(seconds),
                                lastError: error, claim: claim,
                                sentOffset: offset, offsetDevice: offsetDevice)
    }

    // MARK: - Read flags

    /// Reading is a fact, not a preference. A device that has been offline
    /// since before the message was read still holds `isRead == false`, and
    /// its "newer" write must not resurrect the unread badge.
    func testReadingIsMonotonicEvenWhenTheUnreadSideIsNewer() {
        let read = state(isRead: true, at: 0)
        let staleUnread = state(isRead: false, at: 100)
        XCTAssertTrue(WinlinkStateMerge.merge(read, staleUnread, at: t(200)).isRead)
        XCTAssertTrue(WinlinkStateMerge.merge(staleUnread, read, at: t(200)).isRead)
    }

    // MARK: - Filing

    /// Filing has no natural direction, so the latest decision stands — and
    /// the result must not depend on which device ran the merge.
    func testFolderTakesTheMostRecentDecisionAndIsSymmetric() {
        let a = state(folder: 3, at: 10)
        let b = state(folder: 7, at: 20)
        XCTAssertEqual(WinlinkStateMerge.merge(a, b, at: t(30)).folderId, 7)
        XCTAssertEqual(WinlinkStateMerge.merge(b, a, at: t(30)).folderId, 7)
    }

    // MARK: - Delivery state

    /// The dangerous regression: a device that still thinks the message is
    /// queued must not un-send it, or the operator sends it a second time.
    func testSentNeverRegresses() {
        for other: WinlinkMessageStateRecord.DeliveryState in [.draft, .queued, .sending, .failed, .received] {
            XCTAssertEqual(WinlinkStateMerge.mergeDelivery(.sent, other), .sent, "\(other)")
            XCTAssertEqual(WinlinkStateMerge.mergeDelivery(other, .sent), .sent, "\(other)")
        }
    }

    /// A failure outranks the in-progress states it interrupted: the message
    /// did not arrive, and showing it as still sending hides that.
    func testFailureOutranksInProgress() {
        XCTAssertEqual(WinlinkStateMerge.mergeDelivery(.sending, .failed), .failed)
        XCTAssertEqual(WinlinkStateMerge.mergeDelivery(.failed, .queued), .failed)
    }

    func testDeliveryMergeIsSymmetric() {
        let all: [WinlinkMessageStateRecord.DeliveryState] = [.draft, .queued, .sending, .sent, .failed, .received]
        for a in all {
            for b in all {
                XCTAssertEqual(WinlinkStateMerge.mergeDelivery(a, b),
                               WinlinkStateMerge.mergeDelivery(b, a), "\(a) vs \(b)")
            }
        }
    }

    // MARK: - Resume offsets

    /// The failure this rule exists to prevent. Two devices each part-way
    /// through sending the same MID to different gateways; taking the larger
    /// offset would ask a gateway to resume past bytes it never received,
    /// and the message would arrive truncated with no error raised anywhere.
    func testOffsetFollowsTheClaimHolderRatherThanTheLargerNumber() {
        let home = WinlinkTransmitClaim(deviceID: "home", at: t(0))
        let handheld = WinlinkTransmitClaim(deviceID: "ht", at: t(5))

        let homeSide = state(delivery: .sending, at: 10, claim: home,
                             offset: 400, offsetDevice: "home")
        let htSide = state(delivery: .sending, at: 20, claim: handheld,
                           offset: 9_000, offsetDevice: "ht")

        // `home` claimed first, so it keeps the send — and its offset, not
        // the larger one.
        let merged = WinlinkStateMerge.merge(homeSide, htSide, at: t(30))
        XCTAssertEqual(merged.claim?.deviceID, "home")
        XCTAssertEqual(merged.sentOffset, 400)
        XCTAssertEqual(merged.offsetDevice, "home")
    }

    /// With no live claim there is no stream to resume into, so the offset
    /// resets rather than being inherited by whoever picks the message up.
    func testOffsetResetsWhenNoClaimSurvives() {
        let lapsed = WinlinkTransmitClaim(deviceID: "home", claimedAt: t(0), expiresAt: t(60))
        let merged = WinlinkStateMerge.merge(
            state(delivery: .queued, at: 10, claim: lapsed, offset: 400, offsetDevice: "home"),
            state(delivery: .queued, at: 20),
            at: t(9_999))
        XCTAssertNil(merged.claim)
        XCTAssertEqual(merged.sentOffset, 0)
        XCTAssertNil(merged.offsetDevice)
    }

    // MARK: - Mailbox merge

    /// Absence is not deletion. A device that syncs before it has finished
    /// pulling must not be read as having deleted everything it lacks.
    func testMessagesPresentOnOneSideOnlyAreKept() {
        let local = ["A": state("A", at: 0)]
        let remote = ["B": state("B", at: 0)]
        let merged = WinlinkStateMerge.merge(local: local, remote: remote, at: t(10))
        XCTAssertEqual(Set(merged.keys), ["A", "B"])
    }

    func testMailboxMergeIsSymmetric() {
        let local = ["A": state("A", isRead: true, folder: 2, at: 30),
                     "B": state("B", delivery: .sent, at: 5)]
        let remote = ["A": state("A", isRead: false, folder: 9, at: 60),
                      "B": state("B", delivery: .queued, at: 90),
                      "C": state("C", at: 0)]
        let ab = WinlinkStateMerge.merge(local: local, remote: remote, at: t(100))
        let ba = WinlinkStateMerge.merge(local: remote, remote: local, at: t(100))
        XCTAssertEqual(ab, ba)
        XCTAssertTrue(ab["A"]!.isRead)
        XCTAssertEqual(ab["A"]!.folderId, 9)
        XCTAssertEqual(ab["B"]!.deliveryState, .sent)
    }

    /// Merging must converge: a device that re-merges an already-merged
    /// result cannot keep changing its mind, or two devices ping-pong
    /// forever across a sync that never settles.
    func testMergeIsIdempotent() {
        let a = state(isRead: true, folder: 2, delivery: .sending, at: 30,
                      claim: WinlinkTransmitClaim(deviceID: "home", at: t(0)),
                      offset: 128, offsetDevice: "home")
        let b = state(isRead: false, folder: 5, delivery: .failed, at: 60, error: "no answer")
        let once = WinlinkStateMerge.merge(a, b, at: t(90))
        XCTAssertEqual(WinlinkStateMerge.merge(once, once, at: t(90)), once)
        XCTAssertEqual(WinlinkStateMerge.merge(once, a, at: t(90)), once)
        XCTAssertEqual(WinlinkStateMerge.merge(once, b, at: t(90)), once)
    }

    // MARK: - Provisional state

    /// A placeholder must never outrank a decision.
    ///
    /// When a message's content arrives ahead of its state record, sync
    /// seeds a state so the mail is readable. That seed guesses: Inbox,
    /// unread, and — for outbound — `sent`. Merging those guesses field by
    /// field would file mail into the wrong folder and pin a queued message
    /// at `sent`, because `sent` outranks everything by design.
    func testAProvisionalSeedYieldsEntirelyToARealDecision() {
        let seed = state(folder: 1, delivery: .sent,
                         at: WinlinkStateMerge.State.provisionalTimestamp
                             .timeIntervalSince(t0))
        let real = state(isRead: true, folder: 42, delivery: .queued, at: 100)

        XCTAssertTrue(seed.isProvisional)
        XCTAssertEqual(WinlinkStateMerge.merge(seed, real, at: t(200)), real)
        XCTAssertEqual(WinlinkStateMerge.merge(real, seed, at: t(200)), real)
    }

    /// Two placeholders have nothing to choose between, so the ordinary
    /// rules apply rather than one arbitrarily winning.
    func testTwoProvisionalSeedsMergeNormally() {
        let a = state(isRead: true, folder: 1,
                      at: WinlinkStateMerge.State.provisionalTimestamp.timeIntervalSince(t0))
        let b = state(isRead: false, folder: 2,
                      at: WinlinkStateMerge.State.provisionalTimestamp.timeIntervalSince(t0))
        let merged = WinlinkStateMerge.merge(a, b, at: t(10))
        XCTAssertTrue(merged.isRead)
        XCTAssertTrue(merged.isProvisional)
    }

    // MARK: - Record bridging

    func testRecordRoundTripsThroughMerge() {
        let record = WinlinkMessageStateRecord(
            messageId: "MID000000001", folderId: 4, isRead: false,
            deliveryState: WinlinkMessageStateRecord.DeliveryState.queued.rawValue,
            sentOffset: 64, lastError: nil, updatedAt: t(0))

        let remote = state("MID000000001", isRead: true, folder: 4, delivery: .sent, at: 50)
        let merged = WinlinkStateMerge.merge(
            WinlinkStateMerge.State(record: record), remote, at: t(60))
        let applied = merged.applied(to: record)

        XCTAssertTrue(applied.isRead)
        XCTAssertEqual(applied.state, .sent)
        XCTAssertEqual(applied.updatedAt, t(50))
        XCTAssertEqual(applied.messageId, record.messageId)
    }
}

final class WinlinkTransmitClaimTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testUnclaimedMailMayBeSentByAnyone() {
        XCTAssertTrue(WinlinkTransmitClaim.mayTransmit(nil, device: "ht", at: t(0)))
    }

    func testOnlyTheHolderSendsWhileTheClaimIsLive() {
        let claim = WinlinkTransmitClaim(deviceID: "home", at: t(0))
        XCTAssertTrue(WinlinkTransmitClaim.mayTransmit(claim, device: "home", at: t(60)))
        XCTAssertFalse(WinlinkTransmitClaim.mayTransmit(claim, device: "ht", at: t(60)))
    }

    /// A device that loses power mid-session must not strand the message.
    /// Once the claim lapses, the other radio can take it.
    func testALapsedClaimReleasesTheMessage() {
        let claim = WinlinkTransmitClaim(deviceID: "home", at: t(0))
        let afterExpiry = t(WinlinkTransmitClaim.defaultDuration + 1)
        XCTAssertFalse(claim.isActive(at: afterExpiry))
        XCTAssertTrue(WinlinkTransmitClaim.mayTransmit(claim, device: "ht", at: afterExpiry))
    }

    /// The claim window has to outlast a real exchange. This station's own
    /// session log showed a ~19-minute cap on 145.050; a window shorter than
    /// that would lapse mid-send and invite the exact double transmission it
    /// exists to prevent.
    func testClaimOutlastsAMeasuredSessionCap() {
        XCTAssertGreaterThan(WinlinkTransmitClaim.defaultDuration, 1_155 * 2)
    }

    func testEarlierClaimWinsAndBothDevicesAgree() {
        let first = WinlinkTransmitClaim(deviceID: "ht", at: t(0))
        let second = WinlinkTransmitClaim(deviceID: "home", at: t(10))
        XCTAssertEqual(WinlinkTransmitClaim.resolve(first, second, at: t(20)), first)
        XCTAssertEqual(WinlinkTransmitClaim.resolve(second, first, at: t(20)), first)
    }

    /// Two devices claiming in the same instant is unlikely but must still
    /// resolve identically on both sides without another exchange —
    /// otherwise each believes it owns the send.
    func testSimultaneousClaimsBreakTiesDeterministically() {
        let a = WinlinkTransmitClaim(deviceID: "alpha", at: t(0))
        let b = WinlinkTransmitClaim(deviceID: "bravo", at: t(0))
        XCTAssertEqual(WinlinkTransmitClaim.resolve(a, b, at: t(1)), a)
        XCTAssertEqual(WinlinkTransmitClaim.resolve(b, a, at: t(1)), a)
    }

    func testALiveClaimBeatsALapsedOne() {
        let lapsed = WinlinkTransmitClaim(deviceID: "home", claimedAt: t(0), expiresAt: t(60))
        let live = WinlinkTransmitClaim(deviceID: "ht", at: t(100))
        XCTAssertEqual(WinlinkTransmitClaim.resolve(lapsed, live, at: t(120)), live)
        XCTAssertEqual(WinlinkTransmitClaim.resolve(live, lapsed, at: t(120)), live)
    }

    func testTwoLapsedClaimsLeaveTheMessageFree() {
        let a = WinlinkTransmitClaim(deviceID: "home", claimedAt: t(0), expiresAt: t(10))
        let b = WinlinkTransmitClaim(deviceID: "ht", claimedAt: t(5), expiresAt: t(20))
        XCTAssertNil(WinlinkTransmitClaim.resolve(a, b, at: t(100)))
    }
}
