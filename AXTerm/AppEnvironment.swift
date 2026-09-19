//
//  AppEnvironment.swift
//  AXTerm
//
//  One source of truth for "which UserDefaults do we write to". In
//  normal use that is `.standard` — the operator's real preferences and
//  their real learned data (the alias directory, capability verdicts,
//  XID memory). Under `--test-mode` it is an isolated, wiped-on-launch
//  suite, so an instance pointed at the docker test rig cannot touch a
//  single byte of the operator's production data.
//
//  Every UserDefaults-backed store defaults its `defaults:` parameter to
//  `AppEnvironment.defaults`, and the scene sets `.defaultAppStorage`, so
//  isolation is total and automatic — no per-store wiring, nothing to
//  forget.
//

import Foundation

nonisolated enum AppEnvironment {

    /// True when this process is an isolated instance: an explicit
    /// `--test-mode` launch (the rig), or an XCTest host.
    static let isTestMode: Bool = {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--test-mode")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()

    /// True when this process is an XCTest host.
    ///
    /// Narrower than `isTestMode`, deliberately. A `--test-mode` instance is
    /// a real app pointed at the docker rig and is expected to reach it over
    /// the network; an XCTest host is not expected to reach anything.
    static let isUnitTestHost: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Whether this process may open a socket to `host`.
    ///
    /// Under XCTest, loopback only. A test host is injected into the app
    /// bundle and carries the app's identifier, so a connection it opens is
    /// judged by macOS as the app's own — and on 2026-09-17 a full suite run
    /// asking for local network access took the *running* copy's three UDP
    /// streams down with it, one second later, mid-session, while the
    /// operator was on the air.
    ///
    /// Tests that need a peer stand one up on loopback. A test that wants to
    /// reach real hardware is a live test and says so in its own name.
    static func mayConnect(to host: String) -> Bool {
        !isUnitTestHost || isLoopback(host)
    }

    /// Loopback by address or by the names that resolve to it. Not a
    /// security boundary: it is a guard against tests reaching the
    /// operator's network, and a test that lies about its host is only
    /// fooling itself.
    static func isLoopback(_ host: String) -> Bool {
        var name = host.split(separator: "%").first.map(String.init) ?? host
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }

        // Parse it rather than match its spelling. "127.0.0.1.example.com"
        // is a hostname someone else controls, and it begins with "127.".
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 {
            return withUnsafeBytes(of: v6) { raw in
                raw.enumerated().allSatisfy { $0.offset == 15 ? $0.element == 1 : $0.element == 0 }
            }
        }
        return name == "localhost" || name.hasSuffix(".localhost")
    }

    /// The UserDefaults every store and every `@AppStorage` should use.
    /// `.standard` in production; a throwaway suite under test mode,
    /// wiped here on first access so each run starts clean.
    ///
    /// Under XCTest the suite name carries the process id, because a parallel
    /// test run is not one process. `TestModeConfiguration.instanceID` answers
    /// "default" when no instance name, port or callsign was passed — which is
    /// every plain `xcodebuild test` — so every worker clone was opening the
    /// same suite *and wiping it on first access*. Worker B starting up erased
    /// what worker A had just written, from another process, at whatever point
    /// in A's run B happened to launch.
    ///
    /// That is a race no test can defend against and it exists only in
    /// parallel mode, which is the mode a rare cross-worker failure would
    /// appear in. A `--test-mode` instance keeps the named suite it was given:
    /// there the name is the operator's own handle on a rig instance, and two
    /// of those are meant to be told apart by it.
    static let defaults: UserDefaults = {
        guard isTestMode else { return .standard }
        var suite = "com.rosswardrup.AXTerm.test.\(TestModeConfiguration.shared.instanceID)"
        if isUnitTestHost {
            suite += ".pid\(ProcessInfo.processInfo.processIdentifier)"
        }
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        if isUnitTestHost { sweepFinishedWorkerSuites(keeping: suite) }
        return defaults
    }()

    /// Remove the per-worker suites left by test processes that are gone.
    ///
    /// Swept on the way in rather than removed on the way out: a worker is
    /// killed as often as it exits cleanly, and an `atexit` handler that does
    /// not run leaves the plist behind anyway — which is exactly what the first
    /// attempt at this did. Checking which pids are still alive is robust to
    /// however the last run ended.
    private static func sweepFinishedWorkerSuites(keeping current: String) {
        let prefix = "com.rosswardrup.AXTerm.test.\(TestModeConfiguration.shared.instanceID).pid"
        let preferences = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .map { $0.appendingPathComponent("Preferences") }
        for directory in preferences {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where entry.pathExtension == "plist" {
                let name = entry.deletingPathExtension().lastPathComponent
                guard name.hasPrefix(prefix), name != current else { continue }
                guard let pid = Int32(name.dropFirst(prefix.count)) else { continue }
                // ESRCH means no such process: that worker is finished with it.
                guard kill(pid, 0) != 0, errno == ESRCH else { continue }
                UserDefaults().removePersistentDomain(forName: name)
            }
        }
    }
}
