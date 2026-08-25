import Foundation
import Combine

/// Owns the sync engine and decides when it runs.
///
/// Separate from the engine so the rules stay pure and testable: the engine
/// knows how to merge, this knows when to bother. Platform-neutral — the
/// same object drives sync on macOS, iOS and iPadOS.
@MainActor
final class WinlinkSyncController: ObservableObject {

    /// What the operator sees.
    ///
    /// Sync that shows only a spinner is sync nobody trusts: when a message
    /// has not appeared on the other device, the operator needs to know
    /// whether the last pass ran, what it moved, and why it stopped.
    enum Status: Equatable {
        case disabled
        case idle(lastPass: WinlinkSyncEngine.Report?, at: Date?)
        case syncing
        case unavailable(String)
        case failed(String, at: Date)

        var isBusy: Bool { self == .syncing }
    }

    @Published private(set) var status: Status = .disabled
    /// Cumulative since launch, for the settings panel.
    @Published private(set) var messagesReceived = 0

    /// How often a periodic pass runs while the app is open.
    ///
    /// Two minutes: frequent enough that a message read on the handheld
    /// clears on the desktop while the operator is still looking at it, and
    /// rare enough to be invisible on a metered connection. A sync pass with
    /// nothing to do is one small fetch.
    static let periodicInterval: TimeInterval = 120

    private let engine: WinlinkSyncEngine
    private let isEnabled: @MainActor () -> Bool
    private var timerTask: Task<Void, Never>?
    /// Guards against a periodic tick landing on top of a session-triggered
    /// pass. Two concurrent passes are not harmful — the merge is idempotent
    /// — but they waste a round trip and confuse the status.
    private var inFlight: Task<Void, Never>?

    init(engine: WinlinkSyncEngine, isEnabled: @escaping @MainActor () -> Bool) {
        self.engine = engine
        self.isEnabled = isEnabled
    }

    /// Builds a controller over the operator's CloudKit account.
    ///
    /// Returns nil when the store cannot sync — a device with no database
    /// has no mailbox to share, and that should be an absent feature rather
    /// than one that fails on use.
    static func cloudKit(store: WinlinkSyncStore?,
                         identityStore: WinlinkIdentitySyncSource.Store? = nil,
                         contactStore: ContactStore? = nil,
                         activityStore: StationActivityStore? = nil,
                         isEnabled: @escaping @MainActor () -> Bool) -> WinlinkSyncController? {
        guard let store else {
            // Silent nil is why "the Mac isn't pushing" produced no log line
            // at all: every trigger became `sync?.onForeground()` on nothing.
            Telemetry.breadcrumb(
                category: "winlink.sync",
                message: "Sync unavailable: the mailbox database cannot sync on this device",
                level: .warning)
            log("Unavailable — the mailbox database cannot sync on this device")
            return nil
        }
        let transport = CloudKitSyncTransport()

        var sources = WinlinkMessageSyncSource.sources(store: store, deviceID: transport.deviceID)
        // The operator's own details. Without these the policy declares them
        // syncable and nothing carries them, so a second device asks for a
        // callsign it could have inherited.
        if let identityStore {
            sources += WinlinkIdentitySyncSource.sources(store: identityStore)
        }
        // The address book. Declared syncable by the policy since it was
        // written, but nothing carried it until 2026-08-25 — the controller
        // configured four sources and contacts were not among them, while the
        // settings panel told the operator they synced.
        if let contactStore {
            sources.append(WinlinkContactSyncSource(store: contactStore))
        }
        // Attributed, not merged: what another station heard crosses the
        // wire but lands in its own table and its own screen. Passed in as
        // nil when the operator has not opted in, so the source is absent
        // rather than present-and-suppressed — nothing to publish, and
        // nothing arriving to store.
        if let activityStore {
            sources.append(StationActivitySyncSource(
                store: activityStore, deviceID: transport.deviceID))
        }

        Telemetry.breadcrumb(
            category: "winlink.sync",
            message: "Sync configured",
            data: ["sources": sources.count,
                   "kinds": sources.map { $0.kind.rawValue }.joined(separator: ","),
                   "identity": identityStore != nil,
                   "contacts": contactStore != nil,
                   "stationActivity": activityStore != nil])
        log("Configured — \(sources.count) sources: "
            + sources.map { $0.kind.rawValue }.joined(separator: ", "))

        let engine = WinlinkSyncEngine(
            transport: transport, sources: sources,
            tokenStore: WinlinkDefaultsTokenStore())
        return WinlinkSyncController(engine: engine, isEnabled: isEnabled)
    }

    // MARK: - Triggers

    /// App launch, and every return to the foreground.
    ///
    /// Pulls whatever the other device did while this one was closed, which
    /// is the case the operator notices most: opening the desktop app after
    /// working the handheld all afternoon.
    func onForeground() {
        start()
        sync()
    }

    /// Right after an exchange with a gateway.
    ///
    /// The moment new mail exists is the moment it is worth pushing — an
    /// operator who checks their phone straight after a session should find
    /// it there.
    func onSessionFinished() {
        sync()
    }

    func syncNow() {
        sync()
    }

    /// Starts the periodic timer. Idempotent.
    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.periodicInterval))
                guard !Task.isCancelled else { return }
                self?.sync()
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        status = .disabled
    }

    // MARK: - Running

    /// Says it out loud as well as to telemetry.
    ///
    /// Breadcrumbs go to Sentry, which is not running everywhere — it is not
    /// started on iOS at all — so a sync question was unanswerable on exactly
    /// the device most likely to be missing mail. The console is the one
    /// place every platform can be read from.
    private static func log(_ message: String) {
        print("[WINLINK:SYNC] \(message)")
    }

    private func sync() {
        // Every outcome is logged, including the early exits. A pass that
        // does nothing silently is indistinguishable from one that never ran,
        // which makes "is the other device pushing?" unanswerable from a log
        // — and that question is the whole reason sync is hard to debug.
        guard isEnabled() else {
            status = .disabled
            Telemetry.breadcrumb(
                category: "winlink.sync",
                message: "Skipped: mailbox sync is switched off on this device")
            Self.log("Skipped — mailbox sync is switched off on this device")
            return
        }
        guard inFlight == nil else {
            Telemetry.breadcrumb(
                category: "winlink.sync",
                message: "Skipped: a pass is already running")
            Self.log("Skipped — a pass is already running")
            return
        }

        status = .syncing
        Telemetry.breadcrumb(category: "winlink.sync", message: "Pass started")
        Self.log("Pass started")
        inFlight = Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight = nil }
            do {
                let report = try await engine.sync()
                if report.skippedNoAccount {
                    // Not a failure. An operator in the field with no signal
                    // should see why nothing moved, not an error.
                    status = .unavailable("No iCloud account is available on this device.")
                    Telemetry.breadcrumb(
                        category: "winlink.sync",
                        message: "Skipped: no iCloud account on this device",
                        level: .warning)
                    Self.log("Skipped — no iCloud account is available on this device")
                } else {
                    messagesReceived += report.applied
                    status = .idle(lastPass: report, at: Date())
                    Telemetry.breadcrumb(
                        category: "winlink.sync",
                        message: "Pass finished",
                        data: ["pulled": report.pulled, "applied": report.applied,
                               "pushed": report.pushed, "unchanged": report.unchanged,
                               "refused": report.refused,
                               "unreadable": report.unreadable,
                               "wasReset": report.wasReset])
                    Self.log("Pass finished — pulled=\(report.pulled) applied=\(report.applied) "
                             + "pushed=\(report.pushed) unchanged=\(report.unchanged) "
                             + "refused=\(report.refused) unreadable=\(report.unreadable) "
                             + "wasReset=\(report.wasReset)")
                }
            } catch {
                status = .failed(error.localizedDescription, at: Date())
                Telemetry.breadcrumb(
                    category: "winlink.sync",
                    message: "Pass failed",
                    data: ["error": error.localizedDescription],
                    level: .error)
                Self.log("Pass FAILED — \(error)")
            }
        }
    }
}

// MARK: - Status text

extension WinlinkSyncController.Status {

    /// One line for the settings row.
    var summary: String {
        switch self {
        case .disabled:
            return "Off"
        case .syncing:
            return "Syncing\u{2026}"
        case .unavailable(let why):
            return why
        case .failed(let message, _):
            return "Last attempt failed: \(message)"
        case .idle(let report, let at):
            guard let report, let at else { return "Waiting for the first pass" }
            return "\(Self.describe(report)) \u{00B7} \(Self.relative(at))"
        }
    }

    /// The full account, for the tooltip: what moved, and what did not.
    var detail: String {
        switch self {
        case .disabled:
            return "Mail stays on this device. Nothing is sent to iCloud."
        case .syncing:
            return "Fetching changes from the operator's other devices, merging them, then pushing this device's."
        case .unavailable:
            return "Sync is on, but this device cannot reach the account. Mail is unaffected \u{2014} the app works alone and will catch up when the account returns."
        case .failed(let message, let at):
            return "The pass at \(Self.relative(at)) failed: \(message). Nothing was lost; the next pass retries from the last confirmed position."
        case .idle(let report, _):
            guard let report else {
                return "Sync is on but has not run yet. It runs on launch, after every Winlink session, and every two minutes while the app is open."
            }
            var lines = [
                "Pulled \(report.pulled) record(s) from other devices, applied \(report.applied), pushed \(report.pushed).",
            ]
            if report.unreadable > 0 {
                lines.append("\(report.unreadable) record(s) could not be read \u{2014} likely written by a newer version. The rest of the mailbox was unaffected.")
            }
            if report.refused > 0 {
                lines.append("\(report.refused) source(s) were refused by policy: state that describes this radio at this place never leaves the device.")
            }
            if report.wasReset {
                lines.append("The server discarded this device's position, so the pass re-read everything rather than risk missing changes in between.")
            }
            lines.append("Messages, read flags, folders, contacts and callsign lookups sync. Digipeater paths, the gateway ladder, session logs and grid square do not \u{2014} they describe this antenna at this location.")
            return lines.joined(separator: "\n\n")
        }
    }

    private static func describe(_ report: WinlinkSyncEngine.Report) -> String {
        if report.applied == 0 && report.pulled == 0 { return "Up to date" }
        if report.applied == 0 { return "No changes to apply" }
        return "\(report.applied) change(s) applied"
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
