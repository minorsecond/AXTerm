import XCTest
@testable import AXTerm

/// A radio that stops answering while its session stays up.
///
/// The second half of the 2026-09-18 outage. Every UDP stream stayed punctual
/// because the radio keeps pinging on its own schedule whatever else it has
/// stopped doing, so nothing measuring streams could see the fault. The only
/// evidence was on this side: 12,624 CI-V commands sent over four and a half
/// hours and not one answered. Nothing counted the run.
final class CIVUnresponsiveRadioTests: XCTestCase {

    private func client(_ transport: FakeCIVTransport,
                        timeout: TimeInterval = 0.02) -> CIVClient {
        CIVClient(transport: transport, radioAddress: 0xA4,
                  controllerAddress: 0xE0, requestTimeout: timeout)
    }

    /// One unanswered poll is ordinary: a busy radio, a lost datagram.
    func testASingleTimeoutIsNotAVerdict() async {
        let transport = FakeCIVTransport()
        transport.responder = { _ in nil }
        let c = client(transport)
        var reported: String?
        c.onUnresponsive = { reported = $0 }
        c.open()

        _ = try? await c.readFrequency()

        XCTAssertNil(reported, "one silent poll is not a dead radio")
    }

    /// A run of them is the radio.
    ///
    /// Reading `reported` straight after the loop is sound because the client
    /// reports the verdict *before* it resumes the request that reached the
    /// limit, so the `await` below cannot return until the write has happened.
    /// It used to resume first and report second, which left the two lines in
    /// a race the test lost about one full-suite run in three — a race any
    /// caller would lose the same way, seeing the failure and finding no
    /// reason for it.
    func testARunOfUnansweredPollsReportsTheRadioAsIgnoringUs() async {
        let transport = FakeCIVTransport()
        transport.responder = { _ in nil }
        let c = client(transport)
        var reported: String?
        c.onUnresponsive = { reported = $0 }
        c.open()

        for _ in 0..<CIVClient.unansweredPollLimit {
            _ = try? await c.readFrequency()
        }

        XCTAssertNotNil(reported)
        XCTAssertTrue(reported?.contains("in a row") == true)
        // The distinction that matters for the fix: the session is up. This is
        // not a network that stopped carrying.
        XCTAssertTrue(reported?.contains("keepalives") == true)
    }

    /// Reported once on the way past the limit, not on every poll after it.
    /// The outage would otherwise have produced twelve thousand of these.
    func testItReportsOnceRatherThanForever() async {
        let transport = FakeCIVTransport()
        transport.responder = { _ in nil }
        let c = client(transport)
        var count = 0
        c.onUnresponsive = { _ in count += 1 }
        c.open()

        for _ in 0..<(CIVClient.unansweredPollLimit + 6) {
            _ = try? await c.readFrequency()
        }

        XCTAssertEqual(count, 1)
    }

    /// Any frame from the radio ends the run. The question is whether the
    /// radio is answering at all, not whether a particular poll succeeded.
    func testAnAnswerClearsTheRun() async {
        let transport = FakeCIVTransport()
        var answer = false
        transport.responder = { frame in
            answer ? FakeCIVTransport.reply(frame.command, frame.subcommand,
                                            [0x00, 0x00, 0x00, 0x00, 0x00]) : nil
        }
        let c = client(transport)
        var reported: String?
        c.onUnresponsive = { reported = $0 }
        c.open()

        for _ in 0..<(CIVClient.unansweredPollLimit - 1) {
            _ = try? await c.readFrequency()
        }
        answer = true
        _ = try? await c.readFrequency()
        answer = false
        for _ in 0..<(CIVClient.unansweredPollLimit - 1) {
            _ = try? await c.readFrequency()
        }

        XCTAssertNil(reported, "the run restarted when the radio spoke")
    }

    /// Ten seconds of being ignored, give or take, at roughly a poll a second.
    /// Far outside anything a busy radio does and far inside four hours.
    func testTheLimitIsAboutTenSecondsOfBeingIgnored() {
        XCTAssertGreaterThanOrEqual(CIVClient.unansweredPollLimit, 5)
        XCTAssertLessThanOrEqual(CIVClient.unansweredPollLimit, 15)
    }
}
