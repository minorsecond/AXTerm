//
//  NetRomEvidenceModels.swift
//  AXTerm
//
//  Created by Codex on 1/30/26.
//

import Foundation

/// Configuration for passive NET/ROM inference.
struct NetRomInferenceConfig {
    let evidenceWindowSeconds: TimeInterval
    let inferredRouteHalfLifeSeconds: TimeInterval
    let inferredBaseQuality: Int
    let reinforcementIncrement: Int
    let inferredMinimumQuality: Int
    let maxInferredRoutesPerDestination: Int

    static let `default` = NetRomInferenceConfig(
        evidenceWindowSeconds: 5,
        inferredRouteHalfLifeSeconds: 30,
        inferredBaseQuality: 60,
        reinforcementIncrement: 20,
        inferredMinimumQuality: 25,
        maxInferredRoutesPerDestination: 2
    )
}

/// Evidence record for an inferred route.
struct NetRomRouteEvidence: Equatable {
    let destination: String
    let origin: String
    var path: [String]
    var lastObserved: Date
    var reinforcementLevel: Int

    /// Advertised quality derived from reinforcement increments.
    func advertisedQuality(using config: NetRomInferenceConfig) -> Int {
        let boost = max(0, reinforcementLevel - 1) * config.reinforcementIncrement
        let total = config.inferredBaseQuality + boost
        return min(NetRomConfig.maximumRouteQuality, total)
    }

    /// Refresh the evidence timestamp and optionally reinforce it if enough time has elapsed.
    mutating func refresh(timestamp: Date, config: NetRomInferenceConfig) {
        let elapsed = timestamp.timeIntervalSince(lastObserved)
        if elapsed >= config.evidenceWindowSeconds {
            reinforcementLevel += 1
        }
        lastObserved = timestamp
    }
}
