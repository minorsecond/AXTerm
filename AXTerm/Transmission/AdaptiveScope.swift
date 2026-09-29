import Foundation

/// What a piece of adaptive learning is about.
///
/// The tuner adjusts paclen, window size and retry count from observed loss,
/// and those are properties of a **channel**. Two radios are two channels: a
/// busy 1200-baud VHF frequency and a clean 9600-baud UHF link have nothing to
/// teach each other, and averaging them makes the good one carry the bad one's
/// losses. AXTerm used to keep one adaptive state for the whole application
/// plus a per-route cache with no radio in its key, so a destination reachable
/// on two radios was one entry and the network-inference fallback was a single
/// figure applied to every transmission on every radio.
///
/// Timing is not the same shape. RTO comes from SRTT, and SRTT includes the
/// far end's own turnaround — that belongs to a route rather than to a radio.
/// Hence two scopes and a fallback between them: a route learns what it can
/// about itself and inherits the channel underneath it.
nonisolated struct AdaptiveScope: Hashable, Sendable {

    /// One destination over one path. Nil means the radio itself.
    struct Route: Hashable, Sendable {
        let destination: String
        let path: String
    }

    let radio: RadioID
    let route: Route?

    /// Everything crossing one radio. The channel.
    static func radio(_ id: RadioID) -> AdaptiveScope {
        AdaptiveScope(radio: id, route: nil)
    }

    /// One destination over one path on one radio.
    ///
    /// Case-folded and trimmed here, because the same route arrives from a
    /// session, from the compose field and from a saved profile in whatever
    /// case the operator typed. Three spellings would be three keys, each
    /// learning a third as fast.
    static func route(radio: RadioID, destination: String, path: String) -> AdaptiveScope {
        AdaptiveScope(radio: radio,
                      route: Route(destination: destination.trimmingCharacters(in: .whitespaces).uppercased(),
                                   path: path.trimmingCharacters(in: .whitespaces).uppercased()))
    }

    /// Where to look when this scope has learned nothing yet. A route falls
    /// back to its channel; a channel falls back to the operator's configured
    /// baseline, which is the end of the chain rather than another scope.
    var fallback: AdaptiveScope? {
        route == nil ? nil : .radio(radio)
    }

    /// Every scope one sample should update.
    ///
    /// A frame that crossed a route also crossed the radio underneath it, and
    /// the channel figure is the aggregate of everything on it — which is
    /// exactly what a route nobody has used yet will inherit.
    var scopesToTeach: [AdaptiveScope] {
        route == nil ? [self] : [self, .radio(radio)]
    }

    /// The nearest thing already known about this scope, for deciding what
    /// configuration to *use*: the route if we have learned about it, else the
    /// channel it rides on, else the operator's baseline.
    ///
    /// Read-time only, and deliberately so. It is tempting to seed a new
    /// route's *learning* from its channel — but a channel figure is the
    /// aggregate of the routes on it, so seeding either direction lets one
    /// route lend its luck to another. A clean channel would make a bad
    /// digipeated path start out optimistic; a single bad route would make
    /// every other route on the radio start out pessimistic. Both were tried
    /// and both broke route isolation, which is a property worth more than the
    /// faster convergence it was bought with.
    ///
    /// So: each scope learns only from evidence about itself, and what a
    /// channel knows is used to answer "what should I use for a route I know
    /// nothing about yet" — a question whose wrong answer costs one session's
    /// opening parameters rather than a lasting belief.
    static func resolve(_ scope: AdaptiveScope,
                        in learned: [AdaptiveScope: TxAdaptiveSettings],
                        baseline: TxAdaptiveSettings) -> TxAdaptiveSettings {
        var candidate: AdaptiveScope? = scope
        while let current = candidate {
            if let known = learned[current] { return known }
            candidate = current.fallback
        }
        return baseline
    }

    /// How to name this scope to the operator. A per-radio number nobody can
    /// attribute is worse than a global one.
    func label(radioName: (RadioID) -> String?) -> String {
        let radioLabel = radioName(radio) ?? radio.rawValue
        guard let route else { return radioLabel }
        let via = route.path.isEmpty ? "direct" : "via \(route.path)"
        return "\(route.destination) \(via) on \(radioLabel)"
    }
}
