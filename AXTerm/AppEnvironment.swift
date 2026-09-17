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
    static let defaults: UserDefaults = {
        guard isTestMode else { return .standard }
        let suite = "com.rosswardrup.AXTerm.test.\(TestModeConfiguration.shared.instanceID)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }()
}
