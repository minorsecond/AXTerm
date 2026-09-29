import Foundation
import Combine

#if os(macOS)
import AppKit
#endif

/// Why a link went down.
nonisolated enum LinkDropCause: String, Equatable, Sendable, CaseIterable {
    /// Something broke. Worth a red line, worth reporting, worth a backoff.
    case fault
    /// The machine slept, or has only just woken. Expected, nobody's fault,
    /// and the operator should not have to read a POSIX error number to work
    /// out that they closed their laptop.
    case systemSleep
}

/// Deciding whether a drop belongs to a sleep.
///
/// Split out from the monitor so the judgement can be tested against plain
/// dates rather than by putting a Mac to sleep.
nonisolated enum PowerInterruption {

    /// How long after a wake a drop still counts as the sleep's doing.
    ///
    /// Sockets do not fail while the process is frozen, they fail in the first
    /// moments after it thaws: Network.framework catches up, discovers the TCP
    /// connection it was holding is long gone, and reports it then. Ninety
    /// seconds is generous for that catch-up and still far short of the
    /// intervals at which a healthy link fails on its own.
    static let graceAfterWake: TimeInterval = 90

    /// `sleptAt` is when the machine last said it was going to sleep,
    /// `wokeAt` when it last said it was back. Both nil on a machine that has
    /// not slept since launch, which is the common case and always a fault.
    static func cause(dropAt: Date, sleptAt: Date?, wokeAt: Date?) -> LinkDropCause {
        guard let sleptAt, dropAt >= sleptAt else { return .fault }
        guard let wokeAt, wokeAt > sleptAt else {
            // Asleep, or on the way there. Nothing that drops now is a fault.
            return .systemSleep
        }
        // Awake again, so only the catch-up window belongs to the sleep. A
        // negative interval — a drop observed between the sleep and the wake —
        // is inside it by construction.
        return dropAt.timeIntervalSince(wokeAt) <= graceAfterWake ? .systemSleep : .fault
    }

    /// How the gap reads in the console once the machine is back.
    static func outageSummary(from: Date, to: Date,
                              formatter: DateFormatter? = nil) -> String {
        let clock = formatter ?? Self.clockFormatter
        let seconds = max(0, to.timeIntervalSince(from))
        return "Off the air \(clock.string(from: from))–\(clock.string(from: to)) (\(duration(seconds))) — this machine was asleep."
    }

    /// Plain words, because "5880s" is not something anyone wants to divide.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// What the machine's power state is doing, and what that means for the links.
///
/// Exists because on 2026-09-18 the app could not tell the difference between
/// a radio that had failed and a Mac whose display had gone off, and reported
/// both the same way: twenty error-level events describing a symptom, and
/// nothing at all about the cause.
@MainActor
final class SystemPowerMonitor: ObservableObject {

    static let shared = SystemPowerMonitor()

    /// When the machine last said it was going to sleep.
    @Published private(set) var sleptAt: Date?
    /// When it last said it was back.
    @Published private(set) var wokeAt: Date?
    /// When the displays last went off. Tracked separately because it does not
    /// drop a link by itself — it is what App Nap keys on, and knowing it is
    /// the difference between "the operator closed the lid" and "the screen
    /// timed out and we got throttled".
    @Published private(set) var screensSleptAt: Date?

    /// About to go away: the last moment anything can be put on the air.
    let willSleep = PassthroughSubject<Date, Never>()
    /// Back. Carries how long the machine was gone, when that is known.
    let didWake = PassthroughSubject<(at: Date, outage: TimeInterval?), Never>()

    private var observers: [NSObjectProtocol] = []

    /// Whether the machine is away, or was until a moment ago.
    var isAsleep: Bool {
        guard let sleptAt else { return false }
        guard let wokeAt else { return true }
        return wokeAt < sleptAt
    }

    /// Why a drop observed now happened.
    func cause(forDropAt date: Date = Date()) -> LinkDropCause {
        PowerInterruption.cause(dropAt: date, sleptAt: sleptAt, wokeAt: wokeAt)
    }

    /// Begins watching. Separate from `init` so tests can drive the same
    /// object through `noteWillSleep`/`noteDidWake` without a real machine
    /// under them, and so a second call cannot register the handlers twice.
    func start() {
        #if os(macOS)
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteDidWake() }
            },
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensSleptAt = Date() }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensSleptAt = nil }
            }
        ]
        #endif
    }

    func stop() {
        #if os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        #endif
        observers.removeAll()
    }

    /// The machine is going away. Also reachable from tests.
    func noteWillSleep(at date: Date = Date()) {
        sleptAt = date
        willSleep.send(date)
    }

    /// The machine is back. Also reachable from tests.
    func noteDidWake(at date: Date = Date()) {
        let outage = sleptAt.map { date.timeIntervalSince($0) }
        wokeAt = date
        didWake.send((at: date, outage: outage))
    }
}
