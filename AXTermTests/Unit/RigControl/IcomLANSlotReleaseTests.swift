import XCTest
@testable import AXTerm

/// Reclaiming the IC-705's single client slot at connect.
///
/// The radio serves one logged-in client and holds a vacated slot for tens of
/// seconds, refusing a fresh login the whole time. Worse, it can keep the CI-V
/// stream attached to a dead session while granting a new one audio, so every
/// stream we held has to be released. Remembering the streams lets the next
/// launch fire a targeted disconnect at each one. These cover the memory
/// round-trip and the recency window; the send itself is network I/O,
/// exercised against a real radio in the live tests.
final class IcomLANSlotReleaseTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "IcomLANSlotReleaseTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let host = "192.168.3.34"

    private func endpoint(_ local: UInt32, _ remote: UInt32, _ port: UInt16, radioPort: UInt16) -> IcomLANSlotRelease.Endpoint {
        IcomLANSlotRelease.Endpoint(localID: local, remoteID: remote, sourcePort: port, radioPort: radioPort)
    }

    /// The three streams we store come back byte-for-byte to address a release.
    func testRememberedStreamsRoundTrip() {
        let defaults = makeDefaults()
        let streams = [
            endpoint(0xAAAA_0001, 0x1111_0001, 50_001, radioPort: 50_001),
            endpoint(0xAAAA_0002, 0x1111_0002, 50_002, radioPort: 50_002),
            endpoint(0xAAAA_0003, 0x1111_0003, 50_003, radioPort: 50_003)]
        IcomLANSlotRelease.remember(host: host, streams: streams, now: 1_000, defaults: defaults)
        let recalled = IcomLANSlotRelease.recall(host: host, defaults: defaults)
        XCTAssertEqual(recalled?.streams, streams)
        XCTAssertEqual(recalled?.savedAt, 1_000)
    }

    /// A stream that never really came up — remote ID zero, or no bound port —
    /// is dropped, because there is nothing to reclaim on it.
    func testUnusableStreamsAreDropped() {
        let defaults = makeDefaults()
        let good = endpoint(0xAAAA_0001, 0x1111_0001, 50_001, radioPort: 50_001)
        let noRemote = endpoint(0xAAAA_0002, 0, 50_002, radioPort: 50_002)
        let noPort = endpoint(0xAAAA_0003, 0x1111_0003, 0, radioPort: 50_003)
        IcomLANSlotRelease.remember(host: host, streams: [good, noRemote, noPort], now: 1_000, defaults: defaults)
        XCTAssertEqual(IcomLANSlotRelease.recall(host: host, defaults: defaults)?.streams, [good])
    }

    /// Nothing usable means nothing stored.
    func testAllUnusableStoresNothing() {
        let defaults = makeDefaults()
        IcomLANSlotRelease.remember(host: host, streams: [endpoint(1, 0, 0, radioPort: 50_001)],
                                    now: 1_000, defaults: defaults)
        XCTAssertNil(IcomLANSlotRelease.recall(host: host, defaults: defaults))
    }

    private func memory(savedAt: TimeInterval) -> IcomLANSlotRelease.Memory {
        IcomLANSlotRelease.Memory(streams: [endpoint(1, 2, 3, radioPort: 50_001)], savedAt: savedAt)
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
        IcomLANSlotRelease.remember(host: host, streams: [endpoint(1, 2, 3, radioPort: 50_001)],
                                    now: 1_000, defaults: defaults)
        IcomLANSlotRelease.forget(host: host, defaults: defaults)
        XCTAssertNil(IcomLANSlotRelease.recall(host: host, defaults: defaults))
    }

    /// The core of the fix: a release goes to EVERY stream we held, not just
    /// control — a `disconnect` (0x05) naming that stream's own session IDs,
    /// to its radio port, from the source port the radio knew it by. This is
    /// what frees a stale CI-V attachment instead of leaving a new session with
    /// audio and no answers.
    func testReleasePacketsCoverEveryStreamWithADisconnect() {
        let streams = [
            endpoint(0x1100_0001, 0x2200_0001, 40_001, radioPort: 50_001),   // control
            endpoint(0x1100_0002, 0x2200_0002, 40_002, radioPort: 50_002),   // CI-V / serial
            endpoint(0x1100_0003, 0x2200_0003, 40_003, radioPort: 50_003)]   // audio
        let memory = IcomLANSlotRelease.Memory(streams: streams, savedAt: 1_000)

        let releases = IcomLANSlotRelease.releasePackets(for: memory)
        XCTAssertEqual(releases.count, 3, "one release per stream we held")

        // Every radio port is targeted exactly once, from its own source port.
        XCTAssertEqual(releases.map(\.radioPort), [50_001, 50_002, 50_003])
        XCTAssertEqual(releases.map(\.fromPort), [40_001, 40_002, 40_003])

        // Every packet is a disconnect (0x05) carrying that stream's IDs.
        for (release, stream) in zip(releases, streams) {
            guard let header = IcomLAN.Header.parse(release.bytes) else {
                return XCTFail("release packet did not parse as an IcomLAN control frame")
            }
            XCTAssertEqual(header.type, IcomLAN.PacketType.disconnect.rawValue, "must be a disconnect")
            XCTAssertEqual(header.senderID, stream.localID)
            XCTAssertEqual(header.receiverID, stream.remoteID)
        }
    }

    /// Each radio's session is remembered on its own key; releasing one radio's
    /// slot must never depend on or disturb another's.
    func testEachHostIsRememberedSeparately() {
        let defaults = makeDefaults()
        IcomLANSlotRelease.remember(host: "192.168.3.34", streams: [endpoint(1, 2, 3, radioPort: 50_001)],
                                    now: 1_000, defaults: defaults)
        IcomLANSlotRelease.remember(host: "192.168.3.99", streams: [endpoint(9, 8, 7, radioPort: 50_001)],
                                    now: 1_000, defaults: defaults)
        XCTAssertEqual(IcomLANSlotRelease.recall(host: "192.168.3.34", defaults: defaults)?.streams.first?.localID, 1)
        XCTAssertEqual(IcomLANSlotRelease.recall(host: "192.168.3.99", defaults: defaults)?.streams.first?.localID, 9)
    }
}
