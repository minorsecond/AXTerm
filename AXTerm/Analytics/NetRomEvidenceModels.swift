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
    let dataProgressWeight: Double
    let routingBroadcastWeight: Double
    let uiBeaconWeight: Double
    let ackOnlyWeight: Double
    let retryPenaltyMultiplier: Double

    static let `default` = NetRomInferenceConfig(
        evidenceWindowSeconds: 5,
        inferredRouteHalfLifeSeconds: 30,
        inferredBaseQuality: 60,
        reinforcementIncrement: 20,
        inferredMinimumQuality: 25,
        maxInferredRoutesPerDestination: 2,
        dataProgressWeight: 1.0,
        routingBroadcastWeight: 0.8,
        uiBeaconWeight: 0.4,
        ackOnlyWeight: 0.1,
        retryPenaltyMultiplier: 0.7
    )

    func weight(for classification: PacketClassification) -> Double {
        switch classification {
        case .dataProgress: return dataProgressWeight
        case .routingBroadcast: return routingBroadcastWeight
        case .uiBeacon: return uiBeaconWeight
        case .ackOnly: return ackOnlyWeight
        case .retryOrDuplicate: return 0.0
        case .sessionControl: return 0.0
        case .unknown: return 0.0
        }
    }
}

/// Evidence record for an inferred route.
struct NetRomRouteEvidence: Equatable {
    let destination: String
    let origin: String
    var path: [String]
    var lastObserved: Date
    var reinforcementScore: Double

    /// Advertised quality derived from reinforcement increments.
    func advertisedQuality(using config: NetRomInferenceConfig) -> Int {
        let boost = max(0.0, reinforcementScore) * Double(config.reinforcementIncrement)
        let total = Double(config.inferredBaseQuality) + boost
        return min(NetRomConfig.maximumRouteQuality, Int(round(total)))
    }

    /// Refresh the evidence timestamp and optionally reinforce it if enough time has elapsed.
    mutating func refresh(timestamp: Date, classification: PacketClassification, config: NetRomInferenceConfig, isRetry: Bool) {
        let elapsed = timestamp.timeIntervalSince(lastObserved)
        let weight = config.weight(for: classification)
        if elapsed >= config.evidenceWindowSeconds && weight > 0 {
            reinforcementScore += weight
        }
        if isRetry {
            reinforcementScore *= config.retryPenaltyMultiplier
        }
        lastObserved = timestamp
    }
}
