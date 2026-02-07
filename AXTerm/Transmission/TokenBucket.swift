//
//  TokenBucket.swift
//  AXTerm
//
//  Token bucket rate limiter for TX pacing.
//  Spec reference: AXTERM-TRANSMISSION-SPEC.md Section 11.2
//

import Foundation

/// Token bucket rate limiter for controlling TX pacing.
///
/// The token bucket algorithm allows bursts up to `capacity` while maintaining
/// a long-term average rate of `ratePerSec`. This prevents firehosing KISS
/// while still allowing short bursts when the channel is available.
///
/// Usage:
/// ```swift
/// var bucket = TokenBucket(ratePerSec: 2, capacity: 10, now: Date().timeIntervalSince1970)
/// if bucket.allow(cost: frameSize, now: currentTime) {
///     // OK to send
/// }
/// ```
struct TokenBucket {
    private var tokens: Double
    private let ratePerSec: Double
    private let capacity: Double
    private var lastRefill: TimeInterval

    /// Create a new token bucket.
    /// - Parameters:
    ///   - ratePerSec: Token refill rate (tokens per second)
    ///   - capacity: Maximum tokens (burst capacity)
    ///   - now: Current time (for testability)
    init(ratePerSec: Double, capacity: Double, now: TimeInterval) {
        self.ratePerSec = ratePerSec
        self.capacity = capacity
        self.tokens = capacity  // Start full
        self.lastRefill = now
    }

    /// Check if an action with the given cost is allowed, consuming tokens if so.
    /// - Parameters:
    ///   - cost: Token cost of the action (e.g., frame bytes)
    ///   - now: Current time
    /// - Returns: `true` if allowed (tokens consumed), `false` if denied
    mutating func allow(cost: Double, now: TimeInterval) -> Bool {
        refill(now: now)

        if tokens >= cost {
            tokens -= cost
            return true
        }
        return false
    }

    /// Peek at available tokens without consuming.
    /// - Parameter now: Current time
    /// - Returns: Available token count
    mutating func available(now: TimeInterval) -> Double {
        refill(now: now)
        return tokens
    }

    /// Estimate time until a given cost can be afforded.
    /// - Parameters:
    ///   - cost: Token cost needed
    ///   - now: Current time
    /// - Returns: Estimated wait time in seconds (0 if immediately available)
    mutating func timeUntilAvailable(cost: Double, now: TimeInterval) -> TimeInterval {
        refill(now: now)

        if tokens >= cost {
            return 0
        }

        let needed = cost - tokens
        return needed / ratePerSec
    }

    /// Reset bucket to full capacity.
    /// - Parameter now: Current time
    mutating func reset(now: TimeInterval) {
        tokens = capacity
        lastRefill = now
    }

    /// Refill tokens based on elapsed time.
    private mutating func refill(now: TimeInterval) {
        let dt = max(0, now - lastRefill)
        tokens = min(capacity, tokens + dt * ratePerSec)
        lastRefill = now
    }
}

// MARK: - Per-Destination Bucket Manager

/// Manages token buckets per destination for fair scheduling.
final class TokenBucketManager {
    private var buckets: [String: TokenBucket] = [:]
    private let defaultRate: Double
    private let defaultCapacity: Double

    /// Create a bucket manager with default parameters.
    /// - Parameters:
    ///   - defaultRate: Default rate for new buckets (tokens/sec)
    ///   - defaultCapacity: Default capacity for new buckets
    init(defaultRate: Double = 2.0, defaultCapacity: Double = 10.0) {
        self.defaultRate = defaultRate
        self.defaultCapacity = defaultCapacity
    }

    /// Check if sending to a destination is allowed, consuming tokens if so.
    /// - Parameters:
    ///   - destination: Destination identifier (e.g., callsign)
    ///   - cost: Token cost
    ///   - now: Current time
    /// - Returns: `true` if allowed
    func allow(destination: String, cost: Double, now: TimeInterval) -> Bool {
        // Get or create bucket
        if buckets[destination] == nil {
            buckets[destination] = TokenBucket(ratePerSec: defaultRate, capacity: defaultCapacity, now: now)
        }

        // Allow modifies in place
        return buckets[destination]!.allow(cost: cost, now: now)
    }

    /// Peek at available tokens for a destination without consuming.
    /// - Parameters:
    ///   - destination: Destination identifier
    ///   - now: Current time
    /// - Returns: Available token count
    func available(destination: String, now: TimeInterval) -> Double {
        if buckets[destination] == nil {
            buckets[destination] = TokenBucket(ratePerSec: defaultRate, capacity: defaultCapacity, now: now)
        }
        return buckets[destination]!.available(now: now)
    }

    /// Reset a destination's bucket to full capacity.
    /// - Parameters:
    ///   - destination: Destination identifier
    ///   - now: Current time
    func reset(destination: String, now: TimeInterval) {
        buckets[destination]?.reset(now: now)
    }

    /// Remove all buckets (for cleanup).
    func removeAll() {
        buckets.removeAll()
    }
}
