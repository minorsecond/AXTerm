//
//  TelemetryGovernor.swift
//  AXTerm
//
//  Flood control and privacy gating for everything that flows into Sentry.
//
//  Three independent, deterministic pieces (all nonisolated and clock-injected
//  so they unit-test without the SDK):
//
//  - BreadcrumbBudget: per-category token budgets so a busy VHF channel cannot
//    churn the SDK's breadcrumb ring buffer at packet rate. Field measurement
//    (2026-08-22 capture): an ordinary session emitted ~7 crumbs/second, giving
//    a 100-crumb buffer ~14 s of history — the T1/REJ sequence explaining a
//    link failure was always evicted before the failure event shipped.
//
//  - TelemetryContentRedactor: strips over-the-air CONTENT (message previews,
//    payload hex/ascii dumps) from telemetry unless the operator has opted in
//    via the "send packet contents" setting. Third-party traffic relayed
//    through a BBS is other people's mail; it must not leave the machine as a
//    side effect of diagnostics.
//
//  - EventThrottle: collapses repeated identical events (e.g. a garbled KISS
//    stream producing a decode failure per frame) into one event per window
//    with a suppressed count, so a bad RF day is one Sentry issue rather than
//    a quota incident.
//

import Foundation

// MARK: - Breadcrumb Budget

/// Per-category, per-level token budget for breadcrumbs.
///
/// Policy: error-level crumbs always pass (they are rare and load-bearing);
/// warning and info/debug levels each get a fixed budget per category per
/// window. When a window rolls over after drops occurred, the caller is told
/// how many were suppressed so it can emit a single summary crumb — silence is
/// never mistaken for inactivity.
nonisolated struct BreadcrumbBudget: Sendable {
    enum Admission: Equatable, Sendable {
        case allow
        /// Allowed, but `suppressed` crumbs were dropped in the category's
        /// previous window — emit a summary alongside this crumb.
        case allowAfterSuppressing(Int)
        case drop
    }

    struct Policy: Sendable {
        /// Window length in seconds.
        var windowSeconds: TimeInterval = 30
        /// Crumbs allowed per category per window at warning level.
        var warningPerWindow: Int = 60
        /// Crumbs allowed per category per window at info/debug level.
        var infoPerWindow: Int = 20

        static let standard = Policy()
    }

    private struct Window {
        var startedAt: TimeInterval
        var admitted: Int = 0
        var suppressed: Int = 0
    }

    private let policy: Policy
    private var windows: [String: Window] = [:]

    init(policy: Policy = .standard) {
        self.policy = policy
    }

    mutating func admit(category: String, level: SentryBreadcrumbLevel, now: TimeInterval) -> Admission {
        // Errors are never dropped: they are the crumbs that explain failures.
        if level == .error { return .allow }

        let limit = (level == .warning) ? policy.warningPerWindow : policy.infoPerWindow
        // Budget warning and info/debug traffic separately so a debug flood
        // cannot starve warnings in the same category.
        let key = "\(category)|\(level == .warning ? "w" : "i")"

        var window = windows[key] ?? Window(startedAt: now)
        var carriedSuppression = 0
        if now - window.startedAt >= policy.windowSeconds {
            carriedSuppression = window.suppressed
            window = Window(startedAt: now)
        }

        if window.admitted < limit {
            window.admitted += 1
            windows[key] = window
            return carriedSuppression > 0 ? .allowAfterSuppressing(carriedSuppression) : .allow
        }

        window.suppressed += carriedSuppression + 1
        windows[key] = window
        return .drop
    }
}

// MARK: - Content Redaction

/// Removes over-the-air content from telemetry payloads unless the operator
/// has explicitly opted in to sending packet contents.
///
/// Metadata (callsigns, sequence numbers, sizes, timing) always passes —
/// that is what remote diagnosis needs. What gets stripped is the content
/// itself: text previews and payload dumps.
nonisolated enum TelemetryContentRedactor {
    static let placeholder = "[content withheld]"

    /// Keys whose values are over-the-air content (exact, case-sensitive match
    /// — these are our own log call sites, not arbitrary input).
    private static let contentKeys: Set<String> = [
        "preview", "text", "payload", "hex", "ascii", "line", "content", "body", "chunk"
    ]

    /// Key suffixes that mark content-bearing variants (prefixHex, prefixAscii,
    /// infoHex, …). Length-style keys like "textLength"/"payloadLen" do not end
    /// in these suffixes and pass through untouched.
    private static let contentSuffixes = ["Hex", "Ascii", "Preview", "Text"]

    static func isContentKey(_ key: String) -> Bool {
        if contentKeys.contains(key) { return true }
        return contentSuffixes.contains { key.hasSuffix($0) }
    }

    /// Returns `data` with content values replaced by a placeholder.
    /// When `allowContents` is true (operator opt-in), data passes unmodified.
    static func redact(_ data: [String: Any]?, allowContents: Bool) -> [String: Any]? {
        guard let data, !allowContents else { return data }
        var result = data
        for key in result.keys where isContentKey(key) {
            result[key] = placeholder
        }
        return result
    }
}

// MARK: - Shared (thread-safe) instances

/// Process-wide privacy switch mirrored from the user's "send packet contents"
/// setting, so nonisolated telemetry paths (the Telemetry facade runs off the
/// main actor) can honor it without hopping to `SentryManager`.
nonisolated final class TelemetryPrivacy: @unchecked Sendable {
    static let shared = TelemetryPrivacy()
    private let lock = NSLock()
    private var _allowPacketContents = false

    var allowPacketContents: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _allowPacketContents }
        set { lock.lock(); defer { lock.unlock() }; _allowPacketContents = newValue }
    }
}

/// One breadcrumb budget for the whole process, shared by SentryManager and
/// the nonisolated Telemetry backend so all crumbs draw from the same pool.
nonisolated final class SharedBreadcrumbBudget: @unchecked Sendable {
    static let shared = SharedBreadcrumbBudget()
    private let lock = NSLock()
    private var budget = BreadcrumbBudget()

    func admit(
        category: String,
        level: SentryBreadcrumbLevel,
        now: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) -> BreadcrumbBudget.Admission {
        lock.lock(); defer { lock.unlock() }
        return budget.admit(category: category, level: level, now: now)
    }
}

// MARK: - Event Throttle

/// Collapses bursts of identical events into one representative per window.
///
/// The first occurrence always ships immediately. Repeats within the window
/// are counted and suppressed; the next occurrence after the window closes
/// ships with the suppressed count attached.
nonisolated struct EventThrottle: Sendable {
    enum Admission: Equatable, Sendable {
        case allow
        /// Allowed; `suppressed` identical events were dropped since the last
        /// one that shipped — attach the count so volume stays visible.
        case allowAfterSuppressing(Int)
        case drop
    }

    private struct Entry {
        var lastShippedAt: TimeInterval
        var suppressed: Int = 0
    }

    private let windowSeconds: TimeInterval
    private var entries: [String: Entry] = [:]

    init(windowSeconds: TimeInterval = 60) {
        self.windowSeconds = windowSeconds
    }

    mutating func admit(key: String, now: TimeInterval) -> Admission {
        guard var entry = entries[key] else {
            entries[key] = Entry(lastShippedAt: now)
            return .allow
        }
        if now - entry.lastShippedAt >= windowSeconds {
            let suppressed = entry.suppressed
            entries[key] = Entry(lastShippedAt: now)
            return suppressed > 0 ? .allowAfterSuppressing(suppressed) : .allow
        }
        entry.suppressed += 1
        entries[key] = entry
        return .drop
    }
}
