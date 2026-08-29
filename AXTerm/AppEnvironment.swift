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
