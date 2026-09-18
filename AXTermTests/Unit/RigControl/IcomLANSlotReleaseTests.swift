import XCTest
@testable import AXTerm

/// Reclaiming the IC-705's single client slot at connect.
///
/// The radio serves one logged-in client and holds a vacated slot for tens of
/// seconds, refusing a fresh login the whole time. Remembering the last session
/// we held lets the next launch fire a targeted disconnect and take the slot
/// back at once, instead of waiting the refusal out on the login ladder. These
/// cover the memory round-trip and the recency window that decides whether the
/// release is worth sending; the send itself is network I/O, exercised against
/// a real radio in the live tests.
final class IcomLANSlotReleaseTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "IcomLANSlotReleaseTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let host = "192.168.3.34"

    /// What we store on connect comes back byte-for-byte to address the release.
    func testRememberedSessionRoundTrips() {
        let defaults = makeDefaults()
        IcomLANSlotRelease.remember(host: host, localID: 0xABCD_1234, remoteID: 0x9876_5432,
                                    sourcePort: 51_234, now: 1_000, defaults: defaults)
        let recalled = IcomLANSlotRelease.recall(host: host, defaults: defaults)
        XCTAssertEqual(recalled, IcomLANSlotRelease.Memory(localID: 0xABCD_1234, remoteID: 0x9876_5432,
                                                           sourcePort: 51_234, savedAt: 1_000))
    }

    /// A session we never really held — the radio's ID is zero — is not worth
    /// remembering, because there is no slot to reclaim.
    func testASessionWithoutARadioIDIsNotStored() {
        let defaults = makeDefaults()
        IcomLANSlotRelease.remember(host: host, localID: 0xABCD_1234, remoteID: 0,
                                    sourcePort: 51_234, now: 1_000, defaults: defaults)
        XCTAssertNil(IcomLANSlotRelease.recall(host: host, defaults: defaults))
    }

    /// Without a bound source port there is nothing to send the release from,
    /// so there is nothing to store.
    func testASessionWithoutASourcePortIsNotStored() {
        let defaults = makeDefaults()
        IcomLANSlotRelease.remember(host: host, localID: 0xABCD_1234, remoteID: 0x9876_5432,
                                    sourcePort: nil, now: 1_000, defaults: defaults)
        XCTAssertNil(IcomLANSlotRelease.recall(host: host, defaults: defaults))
    }

    private func memory(savedAt: TimeInterval) -> IcomLANSlotRelease.Memory {
        IcomLANSlotRelease.Memory(localID: 1, remoteID: 2, sourcePort: 3, savedAt: savedAt)
    }

    /// A session we left a moment ago is very likely still held; release it.
    func testARecentSessionIsWorthReleasing() {
        XCTAssertTrue(IcomLANSlotRelease.isReclaimable(memory(savedAt: 1_000), now: 1_005))
    }

    /// At the edge of the window it still counts — the radio may cling to the
    /// slot for the full period.
    func testTheEdgeOfTheWindowStillCounts() {
        let now = 1_000 + IcomLANSlotRelease.reclaimWindow
        XCTAssertTrue(IcomLANSlotRelease.isReclaimable(memory(savedAt: 1_000), now: now))
    }

    /// Past the window the slot has certainly lapsed on its own; do not pay for
    /// a session that is already gone.
    func testALapsedSessionIsLeftAlone() {
        let now = 1_000 + IcomLANSlotRelease.reclaimWindow + 1
        XCTAssertFalse(IcomLANSlotRelease.isReclaimable(memory(savedAt: 1_000), now: now))
    }

    /// A clock that stepped backwards leaves the record in the future. Treat it
    /// as current rather than ignore a slot we probably still hold.
    func testAFutureRecordIsTreatedAsCurrent() {
        XCTAssertTrue(IcomLANSlotRelease.isReclaimable(memory(savedAt: 2_000), now: 1_000))
    }

    /// Forgetting clears the record, so a later launch falls back to the
    /// passive path instead of releasing a session that is long gone.
    func testForgettingClearsTheRecord() {
        let defaults = makeDefaults()
        IcomLANSlotRelease.remember(host: host, localID: 1, remoteID: 2, sourcePort: 3,
                                    now: 1_000, defaults: defaults)
        IcomLANSlotRelease.forget(host: host, defaults: defaults)
        XCTAssertNil(IcomLANSlotRelease.recall(host: host, defaults: defaults))
    }

    /// Each radio's session is remembered on its own key; releasing one radio's
    /// slot must never depend on or disturb another's.
    func testEachHostIsRememberedSeparately() {
        let defaults = makeDefaults()
        IcomLANSlotRelease.remember(host: "192.168.3.34", localID: 1, remoteID: 2, sourcePort: 3,
                                    now: 1_000, defaults: defaults)
        IcomLANSlotRelease.remember(host: "192.168.3.99", localID: 9, remoteID: 8, sourcePort: 7,
                                    now: 1_000, defaults: defaults)
        XCTAssertEqual(IcomLANSlotRelease.recall(host: "192.168.3.34", defaults: defaults)?.localID, 1)
        XCTAssertEqual(IcomLANSlotRelease.recall(host: "192.168.3.99", defaults: defaults)?.localID, 9)
    }
}
