import XCTest
@testable import AXTerm

/// Turning a live session into a stored one.
final class TerminalSessionRecorderTests: XCTestCase {

    /// Records what it was told, in order, so the tests can assert on the
    /// shape of the writes rather than only the final state.
    private final class Spy: TerminalSessionStoring, @unchecked Sendable {
        var saved: [TerminalSession] = []
        func save(_ session: TerminalSession) throws { saved.append(session) }
        func sessions(limit: Int) throws -> [TerminalSession] { saved }
        func sessions(withRemote callsign: String) throws -> [TerminalSession] { saved }
        func delete(id: UUID) throws {}
        func deleteAll(forRemote callsign: String) throws -> Int { 0 }
        func setTags(_ tags: [String], for id: UUID) throws {}
        func setNote(_ note: String?, for id: UUID) throws {}
        func tagCounts() throws -> [String: Int] { [:] }
    }

    private let t0 = Date(timeIntervalSince1970: 1_756_000_000)

    /// Written when it opens, not only when it ends. A crash or a power cut
    /// should leave a record that something was attempted rather than
    /// nothing at all.
    func testASessionIsWrittenAsSoonAsItBegins() {
        let spy = Spy()
        let recorder = TerminalSessionRecorder(store: spy)

        recorder.began(id: "a", remote: "DRLNOD", via: [], transport: "AX.25", at: t0)

        XCTAssertEqual(spy.saved.count, 1)
        XCTAssertEqual(spy.saved.first?.remote, "DRLNOD")
        XCTAssertEqual(spy.saved.first?.outcome, .live)
        XCTAssertNil(spy.saved.first?.endedAt)
    }

    /// The same row, updated. A session that opened and closed is one thing
    /// that happened, not two.
    func testEndingUpdatesTheSameSession() {
        let spy = Spy()
        let recorder = TerminalSessionRecorder(store: spy)

        recorder.began(id: "a", remote: "DRLNOD", via: [], transport: "AX.25", at: t0)
        recorder.ended(id: "a", outcome: .closed, at: t0.addingTimeInterval(90))

        XCTAssertEqual(spy.saved.count, 2)
        XCTAssertEqual(spy.saved[0].id, spy.saved[1].id)
        XCTAssertEqual(spy.saved.last?.outcome, .closed)
        XCTAssertEqual(spy.saved.last?.duration, 90)
    }

    /// Lines accumulate in memory and land with the ending. A write per line
    /// would put disk I/O on the path a frame takes to the screen, and a busy
    /// exchange is hundreds of lines.
    func testLinesAreHeldUntilTheSessionEnds() {
        let spy = Spy()
        let recorder = TerminalSessionRecorder(store: spy)

        recorder.began(id: "a", remote: "BBSCBH", via: [], transport: "AX.25", at: t0)
        recorder.recorded(line: "*** CONNECTED", for: "a", sent: false, bytes: 13)
        recorder.recorded(line: "BBS>", for: "a", sent: false, bytes: 4)
        recorder.recorded(line: "L", for: "a", sent: true, bytes: 1)

        XCTAssertEqual(spy.saved.count, 1, "no write per line")

        recorder.ended(id: "a", outcome: .closed, at: t0.addingTimeInterval(30))
        let stored = try? XCTUnwrap(spy.saved.last)
        XCTAssertEqual(stored?.transcript, "*** CONNECTED\nBBS>\nL")
        XCTAssertEqual(stored?.framesReceived, 2)
        XCTAssertEqual(stored?.framesSent, 1)
        XCTAssertEqual(stored?.bytesReceived, 17)
        XCTAssertEqual(stored?.bytesSent, 1)
    }

    /// You connect to a node and then ask it for somewhere else, so the far
    /// end of a relay is not known when the session opens.
    func testTheRelayDestinationCanArriveLate() {
        let spy = Spy()
        let recorder = TerminalSessionRecorder(store: spy)

        recorder.began(id: "a", remote: "DRLNOD", via: [], transport: "AX.25", at: t0)
        recorder.learnedRelayDestination("bbscbh", for: "a")

        XCTAssertEqual(spy.saved.last?.relayDestination, "BBSCBH")
        XCTAssertEqual(spy.saved.last?.correspondent, "BBSCBH",
                       "the conversation is with the far end, not the node")
    }

    /// And it is not overwritten by a later hop, which would relabel the
    /// session as being with whoever was mentioned last.
    func testTheFirstRelayDestinationSticks() {
        let spy = Spy()
        let recorder = TerminalSessionRecorder(store: spy)

        recorder.began(id: "a", remote: "DRLNOD", via: [], transport: "AX.25", at: t0)
        recorder.learnedRelayDestination("BBSCBH", for: "a")
        recorder.learnedRelayDestination("KB5YZB-7", for: "a")

        XCTAssertEqual(spy.saved.last?.relayDestination, "BBSCBH")
    }

    /// Quitting is not the far end hanging up, but from the far end's point
    /// of view the link dropped, and that is what the record should say.
    func testSessionsStillOpenAtShutdownAreRecordedAsDropped() {
        let spy = Spy()
        let recorder = TerminalSessionRecorder(store: spy)

        recorder.began(id: "a", remote: "DRLNOD", via: [], transport: "AX.25", at: t0)
        recorder.began(id: "b", remote: "KB5YZB-7", via: ["DRLNOD"],
                       transport: "Digi", at: t0)
        recorder.closeAll(at: t0.addingTimeInterval(600))

        let finished = spy.saved.filter { $0.outcome == .lost }
        XCTAssertEqual(Set(finished.map(\.remote)), ["DRLNOD", "KB5YZB-7"])
    }

    /// A line for a session that is not open belongs to nothing, and must
    /// not invent one.
    func testALineForAnUnknownSessionIsIgnored() {
        let spy = Spy()
        let recorder = TerminalSessionRecorder(store: spy)

        recorder.recorded(line: "stray", for: "nobody", sent: false, bytes: 5)
        recorder.ended(id: "nobody", outcome: .closed)

        XCTAssertTrue(spy.saved.isEmpty)
    }

    /// History is a nice-to-have; the contact is not. A store that cannot
    /// write must not take the session down with it.
    func testRecordingSurvivesHavingNoStore() {
        let recorder = TerminalSessionRecorder(store: nil)
        recorder.began(id: "a", remote: "DRLNOD", via: [], transport: "AX.25", at: t0)
        recorder.recorded(line: "hello", for: "a", sent: false, bytes: 5)
        recorder.ended(id: "a", outcome: .closed)
    }
}
