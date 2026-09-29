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

    /// Whether the bar starts in Auto-routing rather than a forced protocol.
    ///
    /// Picking a station should just connect the best way it knows — direct if
    /// we've heard it direct, else a digi path, else a NET/ROM circuit, else a
    /// node prompt-relay — without the operator first guessing a protocol. Auto
    /// is the default everywhere except the Routes page, where the operator has
    /// already pointed at one specific NET/ROM route and means it.
    static func defaultAutoRouting(for context: ConnectSourceContext) -> Bool {
        switch context {
        case .routes:
            return false
        case .neighbors, .stations, .terminal, .unknown:
            return true
        }
    }
}

/// What the visible routing switch offers: Auto, or one forced protocol. Auto is
/// its own choice rather than a `ConnectBarMode` case so the mode enum — and the
/// seventeen files that switch on it — stay untouched; `autoRouting` rides
/// alongside `mode`, which remains the fallback the Auto ladder falls through to.
nonisolated enum ConnectRoutingChoice: String, CaseIterable, Hashable, Identifiable {
    case auto
    case direct
    case digi
    case netrom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .direct: return "Direct"
        case .digi: return "Digi"
        case .netrom: return "NET/ROM"
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

/// What gesture produced a connect request.
///
/// The distinction exists because only one of them may key a transmitter.
/// Choosing a name from a dropdown or a list is how an operator *looks* at
/// a station; connecting is a decision to transmit on a shared channel,
/// possibly into a station that is mid-net. Collapsing the two is the kind
/// of surprise that costs somebody else their QSO.
nonisolated enum ConnectOrigin: String, Codable, Equatable, Hashable {
    /// A picker, a list selection, a row click — the operator is choosing
    /// what to look at. Fills the connect bar in; never transmits.
    case selection
    /// A Connect button, or a menu item that says Connect. The operator
    /// asked for the radio.
    case explicitAction
}

nonisolated struct ConnectRequest: Equatable {
    let id: UUID
    let intent: ConnectIntent
    let mode: ConnectBarMode
    let executeImmediately: Bool
    let origin: ConnectOrigin

    /// `executeImmediately` is *clamped*, not trusted.
    ///
    /// A dozen views build these already and a thirteenth is always about
    /// to be written, so the rule lives here where every one of them passes
    /// through. A selection that asks to execute is a bug at the call site;
    /// honouring it would put a radio on the air, so it is downgraded to a
    /// prefill rather than obeyed.
    ///
    /// `origin` defaults to `.selection` on purpose: a call site that has
    /// not thought about this does not get to transmit.
    init(intent: ConnectIntent,
         mode: ConnectBarMode,
         executeImmediately: Bool,
         origin: ConnectOrigin = .selection) {
        self.id = UUID()
        self.intent = intent
        self.mode = mode
        self.origin = origin
        self.executeImmediately = executeImmediately && origin == .explicitAction
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
