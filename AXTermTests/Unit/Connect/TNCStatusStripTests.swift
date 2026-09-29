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


    // MARK: - Several radios

    /// One radio through the array overloads is the single-radio strip,
    /// word for word: parity for the operator with one TNC.
    func testOneRadioIsTheSingleRadioStrip() {
        for status in [ConnectionStatus.connected, .connecting, .disconnected, .failed] {
            let radio = RadioStatusSummary.fixture(status: status)
            XCTAssertEqual(Strip.label([radio]), Strip.label(status))
            XCTAssertEqual(Strip.needsAttention([radio]), Strip.needsAttention(status))
            XCTAssertEqual(Strip.spoken([radio]),
                           Strip.spoken(status, host: "192.168.3.218", port: 8001))
        }
    }

    /// Two working radios earn the same silence one did.
    func testTwoWorkingRadiosSayNothing() {
        let radios: [RadioStatusSummary] = [.fixture(id: "a"), .fixture(id: "b", name: "IC-705")]
        XCTAssertNil(Strip.label(radios))
        XCTAssertFalse(Strip.needsAttention(radios))
    }

    /// The one that is down is named — "a radio is down" would send the
    /// operator hunting.
    func testTheRadioThatNeedsAttentionIsNamed() {
        let base = RadioStatusSummary.fixture(id: "a", name: "Direwolf")
        XCTAssertEqual(Strip.label([base, .fixture(id: "b", name: "IC-705", status: .disconnected)]),
                       "IC-705 not connected")
        XCTAssertEqual(Strip.label([base, .fixture(id: "b", name: "IC-705", status: .failed)]),
                       "IC-705 connection failed")
        XCTAssertEqual(Strip.label([base, .fixture(id: "b", name: "IC-705", status: .connecting)]),
                       "Connecting to IC-705\u{2026}")
        XCTAssertTrue(Strip.needsAttention([base, .fixture(id: "b", status: .failed)]))
    }

    func testSeveralDownAreCounted() {
        let radios: [RadioStatusSummary] = [
            .fixture(id: "a", status: .disconnected),
            .fixture(id: "b", name: "IC-705", status: .failed),
            .fixture(id: "c", name: "Remote", status: .connected),
        ]
        XCTAssertEqual(Strip.label(radios), "2 radios not connected")
    }

    /// Spoken, every radio is listed; there is nowhere else on the screen
    /// that names them.
    func testSpokenListsEveryRadio() {
        let radios: [RadioStatusSummary] = [
            .fixture(id: "a", name: "Direwolf"),
            .fixture(id: "b", name: "IC-705", status: .disconnected, host: "", port: nil,
                     endpoint: "/dev/cu.usbserial-1420"),
        ]
        XCTAssertEqual(Strip.spoken(radios),
                       "Direwolf connected at 192.168.3.218:8001; IC-705 not connected")
    }
}
