//
//  AppSettingsStore.swift
//  AXTerm
//
//  Created by Ross Wardrup on 2/1/26.
//

import Foundation
import Combine

final class AppSettingsStore: ObservableObject {
    static let hostKey = "lastHost"
    static let portKey = "lastPort"
    static let retentionKey = "retentionLimit"
    static let persistKey = "persistHistory"

    static let defaultHost = "localhost"
    static let defaultPort = 8001
    static let defaultRetention = 50_000
    static let minRetention = 1_000
    static let maxRetention = 500_000

    @Published var host: String {
        didSet {
            let sanitized = Self.sanitizeHost(host)
            guard sanitized == host else {
                host = sanitized
                return
            }
            persistHost()
        }
    }

    @Published var port: String {
        didSet {
            let sanitized = Self.sanitizePort(port)
            guard sanitized == port else {
                port = sanitized
                return
            }
            persistPort()
        }
    }

    @Published var retentionLimit: Int {
        didSet {
            let sanitized = Self.sanitizeRetention(retentionLimit)
            guard sanitized == retentionLimit else {
                retentionLimit = sanitized
                return
            }
            persistRetention()
        }
    }

    @Published var persistHistory: Bool {
        didSet { persistPersistHistory() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedHost = defaults.string(forKey: Self.hostKey) ?? Self.defaultHost
        let storedPort = defaults.string(forKey: Self.portKey) ?? String(Self.defaultPort)
        let storedRetention = defaults.object(forKey: Self.retentionKey) as? Int ?? Self.defaultRetention
        let storedPersist = defaults.object(forKey: Self.persistKey) as? Bool ?? true

        self.host = Self.sanitizeHost(storedHost)
        self.port = Self.sanitizePort(storedPort)
        self.retentionLimit = Self.sanitizeRetention(storedRetention)
        self.persistHistory = storedPersist
    }

    var portValue: UInt16 {
        UInt16(Self.sanitizePort(port)) ?? UInt16(Self.defaultPort)
    }

    static func sanitizeHost(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultHost : trimmed
    }

    static func sanitizePort(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let portValue = Int(trimmed) else { return String(defaultPort) }
        let clamped = min(max(portValue, 1), 65_535)
        return String(clamped)
    }

    static func sanitizeRetention(_ value: Int) -> Int {
        min(max(value, minRetention), maxRetention)
    }

    private func persistHost() {
        defaults.set(host, forKey: Self.hostKey)
    }

    private func persistPort() {
        defaults.set(port, forKey: Self.portKey)
    }

    private func persistRetention() {
        defaults.set(retentionLimit, forKey: Self.retentionKey)
    }

    private func persistPersistHistory() {
        defaults.set(persistHistory, forKey: Self.persistKey)
    }
}
