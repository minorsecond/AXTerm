//
//  WinlinkSyncRetry.swift
//  AXTerm
//
//  Which sync failures are worth trying again, and how soon.
//
//  Not every error means the pass failed. The one that prompted this was a
//  CKError 4 wrapping `NSURLErrorNetworkConnectionLost` on a background
//  task, six seconds after the app came back to the foreground (2026-08-28):
//  a connection established earlier, reaped while the app was idle, and
//  written into once more before anyone noticed it was gone. Nothing was
//  wrong with the network or with iCloud. Pressing Sync Now worked
//  immediately, because a second request opens a second connection.
//
//  That mattered more than a stray log line. The controller marked the pass
//  `.failed`, so the header showed a red "Failed" for a condition that would
//  have cleared itself, and the only way to clear it was for the operator to
//  press the button — which is the app asking to be told something it could
//  have found out by asking again.
//
//  Kept apart from the controller because "should this be retried" is a
//  judgement about somebody else's service, and the cases are worth naming
//  one at a time rather than hiding behind a `catch`.
//

import Foundation
import CloudKit

nonisolated enum WinlinkSyncRetry {

    /// Wait before trying again, or nil when trying again is pointless.
    struct Plan: Equatable {
        let delay: TimeInterval
        /// Why, for the log. An operator reading "retrying" deserves to know
        /// what it is retrying against.
        let reason: String
    }

    /// Attempts after the first. Two: a stale connection clears on the
    /// second try, and anything that survives three attempts is a real
    /// outage the operator should be told about rather than watched.
    static let maxRetries = 2

    /// Base wait. CloudKit's own `retryAfterSeconds` wins whenever it is
    /// offered, which is how rate limiting is meant to be honoured.
    static let baseDelay: TimeInterval = 2

    /// Whether an error deserves another attempt, and how long to wait.
    ///
    /// - Parameter attempt: how many attempts have already been made,
    ///   starting at 1 for the first.
    static func plan(for error: Error, attempt: Int) -> Plan? {
        guard attempt <= maxRetries else { return nil }

        if let ckError = error as? CKError {
            // CloudKit says how long to wait for the throttling cases. That
            // number is not advisory: retrying sooner earns a longer one.
            if let after = ckError.retryAfterSeconds, after > 0 {
                return Plan(delay: after, reason: "iCloud asked for \(Int(after))s")
            }
            switch ckError.code {
            case .networkFailure, .networkUnavailable:
                return Plan(delay: backoff(attempt),
                            reason: "the connection dropped")
            case .serviceUnavailable, .zoneBusy, .requestRateLimited:
                return Plan(delay: backoff(attempt), reason: "iCloud was busy")
            default:
                return nil
            }
        }

        // A CKError often carries the URL error underneath, but the sync
        // path can also surface one on its own.
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return nil }
        switch ns.code {
        case NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed:
            return Plan(delay: backoff(attempt), reason: "the connection dropped")
        default:
            return nil
        }
    }

    /// 2s, then 4s. Long enough for a dead socket to be noticed and
    /// replaced, short enough that the operator never sees it happen.
    private static func backoff(_ attempt: Int) -> TimeInterval {
        baseDelay * pow(2, Double(max(0, attempt - 1)))
    }

    /// Whether a foreground pass is worth running, given when the last one
    /// finished.
    ///
    /// The app foregrounds far more often than it has anything to sync — a
    /// dozen transitions in ten minutes in the capture, some of them after
    /// three-second backgrounds, each starting a full pass. Every one of
    /// those is a first request on a possibly-stale connection, so the churn
    /// was not merely wasteful: it was the thing generating the failures.
    static let foregroundDebounce: TimeInterval = 60

    static func shouldSyncOnForeground(lastCompletedAt: Date?, now: Date) -> Bool {
        guard let lastCompletedAt else { return true }
        return now.timeIntervalSince(lastCompletedAt) >= foregroundDebounce
    }
}
