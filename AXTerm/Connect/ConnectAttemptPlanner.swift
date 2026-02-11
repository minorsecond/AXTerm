import Foundation

nonisolated enum ConnectAttemptStep: Equatable {
    case ax25ViaDigis(digis: [String])
    case netrom(nextHopOverride: String?)
}

nonisolated struct ConnectAttemptPlan: Equatable {
    let steps: [ConnectAttemptStep]
}

nonisolated struct ConnectAttemptPlanner {
    static func plan(mode: ConnectBarMode, suggestions: ConnectSuggestions) -> ConnectAttemptPlan {
        switch mode {
        case .ax25ViaDigi:
            let steps = suggestions.recommendedDigiPaths
                .prefix(3)
                .compactMap { candidate -> ConnectAttemptStep? in
                    if candidate.digis.count > 2 {
                        return nil
                    }
                    return .ax25ViaDigis(digis: candidate.digis)
                }
            return ConnectAttemptPlan(steps: Array(steps))

        case .netrom:
            var steps: [ConnectAttemptStep] = [.netrom(nextHopOverride: nil)]
            let overrides = suggestions.recommendedNextHops
                .filter { $0.source != .routePreferred }
                .map { $0.callsign }
            for override in overrides.prefix(2) {
                steps.append(.netrom(nextHopOverride: override))
            }
            return ConnectAttemptPlan(steps: Array(steps.prefix(3)))

        case .ax25:
            return ConnectAttemptPlan(steps: [])
        }
    }
}
