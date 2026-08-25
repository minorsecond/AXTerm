import XCTest
@testable import AXTerm

/// What the always-visible TNC strip says.
///
/// It sits on every screen, so its restraint is load-bearing: a line that
/// shouts when everything is fine trains the operator to stop reading it, and
/// one that stays quiet when the link is down defeats the reason it exists.
final class TNCStatusStripTests: XCTestCase {

    private typealias Strip = TNCStatusStrip.Presentation

    // MARK: - Restraint

    /// A working link spends no words. The dot carries it.
    func testAWorkingLinkSaysNothing() {
        XCTAssertNil(Strip.label(.connected))
        XCTAssertFalse(Strip.needsAttention(.connected))
    }

    /// Connecting explains the pause but does not raise an alarm — a pause
    /// needs explaining before it needs fixing.
    func testConnectingExplainsWithoutAlarming() {
        XCTAssertNotNil(Strip.label(.connecting))
        XCTAssertFalse(Strip.needsAttention(.connecting))
    }

    // MARK: - Speaking up

    /// These are the two the operator has to know about: a packet station
    /// with no link looks exactly like a quiet channel.
    func testABrokenLinkSaysSoPlainly() {
        for status in [ConnectionStatus.disconnected, .failed] {
            XCTAssertTrue(Strip.needsAttention(status), status.rawValue)
            let label = Strip.label(status)
            XCTAssertNotNil(label, status.rawValue)
            XCTAssertTrue(label?.lowercased().contains("tnc") ?? false,
                          "\(status.rawValue) must name what is not connected")
        }
    }

    /// Failure reads differently from never-connected. They need different
    /// actions, so they must not share wording.
    func testFailureIsDistinguishableFromIdle() {
        XCTAssertNotEqual(Strip.label(.failed), Strip.label(.disconnected))
    }

    // MARK: - Spoken

    /// VoiceOver gets the endpoint, because there is no toolbar to glance at
    /// for it.
    func testSpokenStatusNamesTheEndpoint() {
        let spoken = Strip.spoken(.disconnected, host: "100.77.243.13", port: 8001)
        XCTAssertTrue(spoken.contains("100.77.243.13"), spoken)
        XCTAssertTrue(spoken.contains("8001"), spoken)
    }

    /// An unconfigured station has no endpoint to read out, and "at  port 0"
    /// is worse than silence.
    func testSpokenStatusOmitsAnAbsentEndpoint() {
        let spoken = Strip.spoken(.disconnected, host: "", port: 0)
        XCTAssertFalse(spoken.contains("port"), spoken)
        XCTAssertFalse(spoken.contains(" at "), spoken)
    }

    /// Every state is speakable, including the one that shows no text.
    func testEveryStateHasSpokenText() {
        for status in [ConnectionStatus.connected, .connecting, .disconnected, .failed] {
            XCTAssertFalse(Strip.spoken(status, host: "h", port: 1).isEmpty, status.rawValue)
        }
    }
}
