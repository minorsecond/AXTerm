import XCTest
@testable import AXTerm

/// Detecting a second station using this station's callsign.
///
/// The failure this guards against is quiet: two AXTerms on one Direwolf with
/// the same SSID produce sessions that drop for no visible reason. The tests
/// therefore care as much about *not* crying wolf as about catching it —
/// a false alarm on every digipeated frame would be worse than no detection.
final class StationIdentityMonitorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func makeMonitor() -> StationIdentityMonitor { StationIdentityMonitor() }

    // MARK: - The signature

    /// A frame from our own address that we never sent is another station
    /// using our identity. This is the whole point.
    func testAFrameFromOurAddressThatWeDidNotSendIsACollision() {
        let monitor = makeMonitor()
        let collision = monitor.inspectReceived(
            source: "K0EPI-7", destination: "W0ARP-10", control: 0x3F, info: Data(),
            ownCallsign: "K0EPI-7", frameType: "SABM", at: t(0))

        XCTAssertNotNil(collision)
        XCTAssertEqual(collision?.callsign, "K0EPI-7")
        XCTAssertEqual(collision?.destination, "W0ARP-10")
    }

    /// The warning has to tell the operator what to do. "Something is wrong"
    /// costs them the afternoon this detector exists to save.
    func testTheExplanationNamesTheCauseAndTheFix() {
        let monitor = makeMonitor()
        let collision = monitor.inspectReceived(
            source: "K0EPI-7", destination: "W0ARP-10", control: 0x3F, info: Data(),
            ownCallsign: "K0EPI-7", frameType: "SABM", at: t(0))

        let text = collision?.explanation ?? ""
        XCTAssertTrue(text.contains("SSID"), text)
        XCTAssertTrue(text.contains("K0EPI-7"), text)
        XCTAssertTrue(text.lowercased().contains("sequence numbers"), text)
    }

    // MARK: - Not crying wolf

    /// A different SSID is a different station. K0EPI-7 and K0EPI-1 sharing a
    /// TNC is the correct configuration, not a fault.
    func testADifferentSSIDIsNotACollision() {
        let monitor = makeMonitor()
        XCTAssertNil(monitor.inspectReceived(
            source: "K0EPI-1", destination: "W0ARP-10", control: 0x3F, info: Data(),
            ownCallsign: "K0EPI-7", frameType: "SABM", at: t(0)))
    }

    func testAnotherStationEntirelyIsNotACollision() {
        let monitor = makeMonitor()
        XCTAssertNil(monitor.inspectReceived(
            source: "KD0SSP", destination: "BEACON", control: 0x03, info: Data(),
            ownCallsign: "K0EPI-7", frameType: "UI", at: t(0)))
    }

    /// Our own transmission arriving back — some TNC configurations echo it —
    /// must not read as somebody else.
    func testOurOwnFrameComingBackIsNotACollision() {
        let monitor = makeMonitor()
        let info = Data("hello".utf8)
        monitor.recordTransmitted(source: "K0EPI-7", destination: "W0ARP-10",
                                  control: 0x00, info: info, at: t(0))

        XCTAssertNil(monitor.inspectReceived(
            source: "K0EPI-7", destination: "W0ARP-10", control: 0x00, info: info,
            ownCallsign: "K0EPI-7", frameType: "I", at: t(1)))
    }

    /// The case that makes byte comparison useless: a digipeater sets the
    /// has-been-repeated bit, so the frame that returns is not the frame that
    /// left. Fingerprinting the invariant part still recognises it as ours.
    ///
    /// Getting this wrong would fire a collision warning on every single
    /// transmission through DRLNOD, and the operator would learn to ignore
    /// the warning — which is worse than not having it.
    func testADigipeatedEchoIsRecognisedAsOurOwn() {
        let monitor = makeMonitor()
        let info = Data("via the node".utf8)
        monitor.recordTransmitted(source: "K0EPI-7", destination: "W0ARP-10",
                                  control: 0x00, info: info, at: t(0))

        // Comes back seconds later after the digipeater's own channel access,
        // with the path rewritten — which this fingerprint ignores.
        XCTAssertNil(monitor.inspectReceived(
            source: "K0EPI-7", destination: "W0ARP-10", control: 0x00, info: info,
            ownCallsign: "K0EPI-7", frameType: "I", at: t(6)))
    }

    /// A station with no callsign configured has no identity to collide with,
    /// and must not be told it has one.
    func testNoCallsignMeansNoDetection() {
        let monitor = makeMonitor()
        XCTAssertNil(monitor.inspectReceived(
            source: "K0EPI-7", destination: "W0ARP-10", control: 0x3F, info: Data(),
            ownCallsign: "", frameType: "SABM", at: t(0)))
    }

    func testComparisonIgnoresCaseAndWhitespace() {
        let monitor = makeMonitor()
        XCTAssertNotNil(monitor.inspectReceived(
            source: " k0epi-7 ", destination: "W0ARP-10", control: 0x3F, info: Data(),
            ownCallsign: "K0EPI-7", frameType: "SABM", at: t(0)))
    }

    // MARK: - Windows

    /// An echo arriving long after the fact is not an echo. The window has to
    /// close, or a genuine collision that happens to repeat an old frame is
    /// masked forever.
    func testAnEchoOutsideTheWindowIsTreatedAsACollision() {
        let monitor = makeMonitor()
        let info = Data("stale".utf8)
        monitor.recordTransmitted(source: "K0EPI-7", destination: "W0ARP-10",
                                  control: 0x00, info: info, at: t(0))

        let late = t(StationIdentityMonitor.echoWindow + 5)
        XCTAssertNotNil(monitor.inspectReceived(
            source: "K0EPI-7", destination: "W0ARP-10", control: 0x00, info: info,
            ownCallsign: "K0EPI-7", frameType: "I", at: late))
    }

    /// The window must outlast a digipeater's channel access on a busy
    /// channel, or the echo test above is defeated in the field.
    func testTheEchoWindowIsLongEnoughForADigipeater() {
        XCTAssertGreaterThanOrEqual(StationIdentityMonitor.echoWindow, 10)
    }

    /// A collision emits a frame every few seconds. The operator needs
    /// telling once — a warning that repeats is a warning that gets dismissed.
    func testRepeatedCollisionsAreReportedOnce() {
        let monitor = makeMonitor()
        var reports = 0
        for second in stride(from: 0.0, to: 60.0, by: 3.0) {
            if monitor.inspectReceived(
                source: "K0EPI-7", destination: "W0ARP-10", control: 0x3F, info: Data(),
                ownCallsign: "K0EPI-7", frameType: "SABM", at: t(second)) != nil {
                reports += 1
            }
        }
        XCTAssertEqual(reports, 1)
    }

    /// After the quiet period a still-present collision is worth mentioning
    /// again — the operator may have missed the first one.
    func testTheWarningReturnsAfterTheQuietPeriod() {
        let monitor = makeMonitor()
        XCTAssertNotNil(monitor.inspectReceived(
            source: "K0EPI-7", destination: "W0ARP-10", control: 0x3F, info: Data(),
            ownCallsign: "K0EPI-7", frameType: "SABM", at: t(0)))

        let later = t(StationIdentityMonitor.reportInterval + 1)
        XCTAssertNotNil(monitor.inspectReceived(
            source: "K0EPI-7", destination: "W0ARP-10", control: 0x3F, info: Data(),
            ownCallsign: "K0EPI-7", frameType: "SABM", at: later))
    }

    // MARK: - Identity changes

    /// Changing callsign must clear the echo memory. Frames sent as the old
    /// identity are not evidence about the new one, and leaving them in place
    /// would mask a real collision on the address just adopted.
    func testResetClearsTheEchoMemory() {
        let monitor = makeMonitor()
        let info = Data("before".utf8)
        monitor.recordTransmitted(source: "K0EPI-7", destination: "W0ARP-10",
                                  control: 0x00, info: info, at: t(0))
        monitor.reset()

        XCTAssertNotNil(monitor.inspectReceived(
            source: "K0EPI-7", destination: "W0ARP-10", control: 0x00, info: info,
            ownCallsign: "K0EPI-7", frameType: "I", at: t(1)))
    }

    /// Two different frames must not share a fingerprint, or one transmission
    /// would vouch for a frame it has nothing to do with.
    func testDifferentFramesFingerprintDifferently() {
        let base = StationIdentityMonitor.fingerprint(
            source: "K0EPI-7", destination: "W0ARP-10", control: 0x00, info: Data("a".utf8))

        XCTAssertNotEqual(base, StationIdentityMonitor.fingerprint(
            source: "K0EPI-7", destination: "W0ARP-10", control: 0x00, info: Data("b".utf8)))
        XCTAssertNotEqual(base, StationIdentityMonitor.fingerprint(
            source: "K0EPI-7", destination: "W0ARP-10", control: 0x02, info: Data("a".utf8)))
        XCTAssertNotEqual(base, StationIdentityMonitor.fingerprint(
            source: "K0EPI-7", destination: "KD0SSP", control: 0x00, info: Data("a".utf8)))
    }
}

/// The toolbar indicator's own formatting. Small, but it is the one thing the
/// operator reads at a glance, and "0m ago" for a sync that just happened
/// reads as broken.
final class SyncStatusIndicatorFormattingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func label(secondsAgo: TimeInterval) -> String {
        SyncStatusIndicator.relative(now.addingTimeInterval(-secondsAgo), now: now)
    }

    func testAFreshSyncReadsAsJustNow() {
        XCTAssertEqual(label(secondsAgo: 0), "just now")
        XCTAssertEqual(label(secondsAgo: 30), "just now")
    }

    func testMinutesHoursAndDaysAreCompact() {
        XCTAssertEqual(label(secondsAgo: 120), "2m")
        XCTAssertEqual(label(secondsAgo: 3 * 3600), "3h")
        XCTAssertEqual(label(secondsAgo: 2 * 86_400), "2d")
    }

    /// Clock skew between two devices can put a remote timestamp slightly in
    /// the future. "-1m" would look like a bug in the app rather than in the
    /// clocks.
    func testAFutureTimestampDoesNotProduceANegativeLabel() {
        let future = SyncStatusIndicator.relative(now.addingTimeInterval(300), now: now)
        XCTAssertEqual(future, "just now")
    }
}
