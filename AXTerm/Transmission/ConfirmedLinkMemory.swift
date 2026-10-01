//
//  ConfirmedLinkMemory.swift
//  AXTerm
//
//  The K and paclen each link last confirmed, so the next session to the
//  same station on the same path and radio starts there instead of climbing
//  from K=2 paclen 128 again (spec §7.8.1, live RF test 2026-09-30 I-1).
//
//  Only confirmed values are written: an upgrade enters this memory when it
//  survives its probation trial, never while it is on trial. A later backoff
//  lowers an existing record to what the link has fallen back to; nothing
//  raises a record except another confirmed trial. A backoff with no record
//  writes nothing, because a loss response is not a confirmation, and the
//  route's own 30-minute learning already carries that loss into the next
//  session's start.
//
//  Records older than a day are ignored. A day covers the sessions an
//  operator runs to one station in a sitting (a test, a break, more tests;
//  an evening of BBS visits) while staying short of the changes that make an
//  old figure wrong: another radio or power level, a different antenna,
//  band conditions, a peer's TX delay changed overnight. A start that is too
//  high costs little, since the first retransmission halves K and steps
//  paclen down, but there is no reason to pay it with a stale figure.
//
//  Keyed by radio, station and path. A digipeated path's figures say nothing
//  about the direct path to the same station, and two radios are two
//  channels (see AdaptiveScope).
//

import Foundation

nonisolated struct ConfirmedLinkValues: Codable, Equatable, Sendable {
    let window: Int
    let paclen: Int
    let recordedAt: Date
}

nonisolated struct ConfirmedLinkMemory {

    /// How long a record may seed a session.
    static let maxAge: TimeInterval = 24 * 3600

    private static let storageKey = "transmission.confirmedLinkValuesV1"

    /// Where records persist, if anywhere. Nil keeps them for this process
    /// only, which is what tests and bare managers get: a record written by
    /// one test must never seed another's session.
    private let defaults: UserDefaults?
    private var records: [String: ConfirmedLinkValues]

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let defaults,
           let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String: ConfirmedLinkValues].self, from: data) {
            records = stored
        } else {
            records = [:]
        }
    }

    /// Route scopes only. A channel figure is an aggregate of routes and is
    /// never what a link confirmed.
    private static func key(for scope: AdaptiveScope) -> String? {
        guard let route = scope.route else { return nil }
        let destination = canonical(route.destination)
        let path = route.path.trimmingCharacters(in: .whitespaces).uppercased()
        guard !destination.isEmpty else { return nil }
        return "\(scope.radio.rawValue)|\(destination)|\(path)"
    }

    /// "PEER" and "PEER-0" are one station.
    private static func canonical(_ destination: String) -> String {
        let upper = destination.trimmingCharacters(in: .whitespaces).uppercased()
        return upper.hasSuffix("-0") ? String(upper.dropLast(2)) : upper
    }

    /// The record for this link, if it is less than a day old.
    func values(for scope: AdaptiveScope, now: Date = Date()) -> ConfirmedLinkValues? {
        guard let key = Self.key(for: scope), let record = records[key] else { return nil }
        guard now.timeIntervalSince(record.recordedAt) <= Self.maxAge else { return nil }
        return record
    }

    /// An upgrade passed its trial: these values are what the link carries.
    mutating func recordConfirmed(window: Int, paclen: Int, for scope: AdaptiveScope,
                                  at now: Date = Date()) {
        guard let key = Self.key(for: scope) else { return }
        records[key] = ConfirmedLinkValues(window: window, paclen: paclen, recordedAt: now)
        save()
    }

    /// The link backed off. An existing record is lowered to at most these
    /// values; a missing one stays missing.
    mutating func lower(window: Int, paclen: Int, for scope: AdaptiveScope,
                        at now: Date = Date()) {
        guard let key = Self.key(for: scope), let record = records[key] else { return }
        let lowered = ConfirmedLinkValues(window: min(record.window, window),
                                          paclen: min(record.paclen, paclen),
                                          recordedAt: now)
        guard lowered.window != record.window || lowered.paclen != record.paclen else { return }
        records[key] = lowered
        save()
    }

    /// Forget one station on every path and radio.
    mutating func remove(destination: String) {
        let wanted = Self.canonical(destination)
        let before = records.count
        records = records.filter { key, _ in
            key.split(separator: "|", omittingEmptySubsequences: false).dropFirst().first
                .map(String.init) != wanted
        }
        if records.count != before { save() }
    }

    mutating func removeAll() {
        guard !records.isEmpty else { return }
        records.removeAll()
        save()
    }

    private func save() {
        guard let defaults else { return }
        // Expired records are dropped on the way out so the store stays small.
        let fresh = records.filter { Date().timeIntervalSince($0.value.recordedAt) <= Self.maxAge }
        guard let data = try? JSONEncoder().encode(fresh) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
