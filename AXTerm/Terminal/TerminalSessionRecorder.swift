import Foundation

/// Turns a live session into a stored one.
///
/// Kept apart from the terminal view because the rules are about evidence
/// rather than layout, and because a view that is torn down on navigation is
/// the wrong owner for something that must outlive the app.
/// Deliberately not `@MainActor`, and deliberately not an
/// `ObservableObject`.
///
/// It publishes nothing: the terminal shows live sessions from its own state
/// and the browser reads the store. Conforming anyway cost a real bug. A
/// `@MainActor` class whose deinit runs off the main actor calls `abort()`,
/// which surfaces as a test failing in 0.000 seconds with no message at all
/// — three separate times today before the result bundle was read:
///
///     Crash: AXTerm at TerminalSessionRecorder.__deallocating_deinit.
///     libsystem_c.dylib: abort() called
///
/// A plain class with a lock has no isolation to violate, and the lock is
/// honest about what this actually needs: frames arrive off the radio's
/// thread and the operator disconnects on the main one.
nonisolated final class TerminalSessionRecorder: @unchecked Sendable {

    /// Sessions currently open, by the id the terminal knows them under.
    private var open: [String: TerminalSession] = [:]
    private let lock = NSLock()
    private let store: TerminalSessionStoring?

    init(store: TerminalSessionStoring?) {
        self.store = store
    }

    /// A session began. Written immediately rather than at the end, so a
    /// crash or a power cut leaves a record that something was attempted
    /// instead of nothing at all.
    func began(id: String, remote: String, via: [String], transport: String,
               relayDestination: String? = nil, at when: Date = Date()) {
        let session = TerminalSession(
            remote: remote, via: via, relayDestination: relayDestination,
            transport: transport, startedAt: when, outcome: .live)
        lock.withLock { open[id] = session }
        persist(session)
    }

    /// The far end of a relay chain became known partway through, which is
    /// normal: you connect to a node and then ask it for somewhere else.
    func learnedRelayDestination(_ destination: String, for id: String) {
        let updated: TerminalSession? = lock.withLock {
            guard var session = open[id], session.relayDestination == nil else { return nil }
            session.relayDestination = destination.uppercased()
            open[id] = session
            return session
        }
        guard let updated else { return }
        persist(updated)
    }

    /// One line of the conversation.
    ///
    /// Appended in memory and written when the session ends, not on every
    /// line: a busy exchange is hundreds of lines and a database write per
    /// line would put disk I/O on the path a frame takes to the screen.
    func recorded(line: String, for id: String, sent: Bool, bytes: Int) {
        lock.withLock {
            guard var session = open[id] else { return }
            if !session.transcript.isEmpty { session.transcript += "\n" }
            session.transcript += line
            if sent {
                session.framesSent += 1
                session.bytesSent += bytes
            } else {
                session.framesReceived += 1
                session.bytesReceived += bytes
            }
            open[id] = session
        }
    }

    /// The session ended, however it ended.
    func ended(id: String, outcome: TerminalSession.Outcome, at when: Date = Date()) {
        let finished: TerminalSession? = lock.withLock {
            guard var session = open.removeValue(forKey: id) else { return nil }
            session.outcome = outcome
            session.endedAt = when
            return session
        }
        guard let finished else { return }
        persist(finished)
    }

    /// Everything still open was cut off by the app closing rather than by
    /// anything on the air. Recorded as dropped, which is what happened from
    /// the far end's point of view.
    func closeAll(at when: Date = Date()) {
        for id in lock.withLock({ Array(open.keys) }) {
            ended(id: id, outcome: .lost, at: when)
        }
    }

    /// Never at the cost of the session it is recording. A failed write
    /// loses history, which is a nuisance; a failed write that interrupts a
    /// connection loses the contact, which is not.
    private func persist(_ session: TerminalSession) {
        guard let store else { return }
        try? store.save(session)
    }
}
