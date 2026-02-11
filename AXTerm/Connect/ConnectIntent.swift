import Foundation

typealias CallsignSSID = Callsign

nonisolated enum ConnectSourceContext: String, Codable, CaseIterable, Hashable {
    case terminal
    case routes
    case neighbors
    case stations
    case unknown
}

nonisolated enum ConnectBarMode: String, Codable, CaseIterable, Hashable {
    case ax25 = "AX.25"
    case ax25ViaDigi = "AX.25 via Digi"
    case netrom = "NET/ROM"

    static func defaultMode(for context: ConnectSourceContext) -> ConnectBarMode {
        switch context {
        case .routes:
            return .netrom
        case .neighbors, .stations, .terminal, .unknown:
            return .ax25
        }
    }
}

nonisolated enum ConnectKind: Equatable, Hashable {
    case ax25Direct
    case ax25ViaDigis([CallsignSSID])
    case netrom(nextHopOverride: CallsignSSID?)
}

nonisolated struct NetRomRouteHint: Equatable, Hashable {
    let nextHop: String?
    let heardAs: String?
    let path: [String]
    let hops: Int
}

nonisolated struct ConnectIntent: Equatable, Hashable {
    let kind: ConnectKind
    let to: String
    let sourceContext: ConnectSourceContext
    let suggestedRoutePreview: String?
    let validationErrors: [String]
    let routeHint: NetRomRouteHint?
    let note: String?

    var normalizedTo: String {
        CallsignValidator.normalize(to)
    }
}

nonisolated struct ConnectRequest: Equatable {
    let id: UUID
    let intent: ConnectIntent
    let mode: ConnectBarMode
    let executeImmediately: Bool

    init(intent: ConnectIntent, mode: ConnectBarMode, executeImmediately: Bool) {
        self.id = UUID()
        self.intent = intent
        self.mode = mode
        self.executeImmediately = executeImmediately
    }
}

nonisolated enum ConnectAttemptResult: String, Codable {
    case success
    case failed
}

nonisolated enum ConnectPrefillLogic {
    static func ax25DirectTarget(destination: String, heardAs: String?) -> (to: String, note: String?) {
        let normalizedDestination = CallsignValidator.normalize(destination)
        let normalizedHeardAs = CallsignValidator.normalize(heardAs ?? "")
        if !normalizedHeardAs.isEmpty, normalizedHeardAs != normalizedDestination {
            return (normalizedHeardAs, "Heard as: \(normalizedHeardAs)")
        }
        return (normalizedDestination, nil)
    }

    static func shouldNavigateOnConnect(_ request: ConnectRequest) -> Bool {
        request.executeImmediately
    }

    static func fallbackDigipeaters(
        destination: String,
        hint: NetRomRouteHint?,
        nextHopOverride: CallsignSSID?
    ) -> [String] {
        if let override = nextHopOverride {
            return [override.stringValue]
        }

        guard let hint else { return [] }
        let destinationNorm = CallsignValidator.normalize(destination)
        var path = hint.path.map { CallsignValidator.normalize($0) }.filter { !$0.isEmpty }

        if path.last == destinationNorm {
            path.removeLast()
        }
        if path.first == destinationNorm {
            path.removeFirst()
        }

        if path.isEmpty,
           let nextHop = hint.nextHop.map(CallsignValidator.normalize),
           !nextHop.isEmpty,
           nextHop != destinationNorm {
            path = [nextHop]
        }

        return DigipeaterListParser.capped(path)
    }
}
