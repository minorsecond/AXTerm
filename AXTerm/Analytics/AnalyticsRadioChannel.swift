import Foundation

/// A frequency channel the analytics page can scope to.
///
/// Two radios on the *same* frequency hear the same air — the receiver folds
/// their duplicate copies into one packet at ingest (`CrossRadioDedup`), so
/// they are one channel and their traffic must roll up, not double. Two radios
/// on *different* frequencies hear disjoint populations (145.050 packet vs
/// 144.390 APRS), so their neighbours, routes and link quality must never be
/// averaged together — they are separate channels. A radio whose frequency is
/// unknown is its own channel: we cannot claim it shares a band with anything.
///
/// This is the primitive the roll-up-vs-split decision rests on, inferred from
/// each radio's `frequencyHz` exactly as the plan asks.
nonisolated struct AnalyticsRadioChannel: Identifiable, Equatable, Sendable {
    /// Stable across rebuilds: a frequency channel is keyed by its frequency,
    /// an unknown-frequency channel by its single radio, so the operator's
    /// selection survives a radio reconnecting or being renamed.
    let id: String
    /// What the picker shows: "144.390 MHz", or the radio's name when the
    /// frequency is unknown.
    let label: String
    /// The shared frequency, or nil for an unknown-frequency channel.
    let frequencyHz: Int?
    /// Every radio on this channel. Membership is what scopes the packets.
    let radioIDs: Set<RadioID>

    /// A radio, reduced to what channel grouping needs.
    nonisolated struct Radio: Equatable, Sendable {
        var id: RadioID
        var name: String
        var frequencyHz: Int?
    }

    /// Groups visible radios into channels by frequency. Hidden radios are
    /// dropped — the analytics filter honours the same hidden set as the map
    /// and the packets table. Radios sharing a frequency become one channel;
    /// radios with no known frequency each become their own. Deterministic
    /// order: by frequency ascending, then unknown-frequency channels by name,
    /// so the picker never reshuffles under the operator.
    static func channels(radios: [Radio], hidden: Set<RadioID>) -> [AnalyticsRadioChannel] {
        let visible = radios.filter { !hidden.contains($0.id) }

        var byFrequency: [Int: [Radio]] = [:]
        var unknown: [Radio] = []
        for radio in visible {
            if let hz = radio.frequencyHz {
                byFrequency[hz, default: []].append(radio)
            } else {
                unknown.append(radio)
            }
        }

        var result: [AnalyticsRadioChannel] = []
        for hz in byFrequency.keys.sorted() {
            let group = byFrequency[hz] ?? []
            result.append(AnalyticsRadioChannel(
                id: "freq:\(hz)",
                label: frequencyLabel(hz),
                frequencyHz: hz,
                radioIDs: Set(group.map(\.id))))
        }
        for radio in unknown.sorted(by: { $0.name < $1.name }) {
            result.append(AnalyticsRadioChannel(
                id: "radio:\(radio.id.rawValue)",
                label: radio.name,
                frequencyHz: nil,
                radioIDs: [radio.id]))
        }
        return result
    }

    /// "144.390 MHz" — the frequency at the precision an operator reads on the
    /// dial, trailing zeros trimmed.
    static func frequencyLabel(_ hz: Int) -> String {
        let mhz = Double(hz) / 1_000_000
        var text = String(format: "%.4f", mhz)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text) MHz"
    }
}

/// What the analytics page is scoped to: every visible radio, or one channel.
nonisolated enum AnalyticsRadioScope: Hashable, Sendable {
    case all
    case channel(String)
}

/// Filters packets to an analytics radio scope.
///
/// Hidden radios are always dropped, whatever the scope — the same rule the
/// map and packets table apply, now reaching analytics too. A specific channel
/// additionally keeps only packets its radios heard. `.all` keeps everything
/// visible; same-frequency copies were already folded at ingest, so pooling
/// visible radios does not double-count a shared air event.
nonisolated enum AnalyticsRadioFilter {
    static func apply(_ packets: [Packet],
                      scope: AnalyticsRadioScope,
                      channels: [AnalyticsRadioChannel],
                      hidden: Set<RadioID>) -> [Packet] {
        let selection = selection(scope: scope, channels: channels, hidden: hidden)
        // With one channel and nothing hidden there is nothing to scope, so
        // the array is returned untouched — the single-radio case pays nothing.
        guard !selection.admitsEveryRadio else { return packets }
        return packets.filter { selection.admits($0.radioID ?? .primary) }
    }

    /// The same decision as a value, for the aggregation that runs in SQLite
    /// and so cannot filter packets before counting them.
    static func selection(scope: AnalyticsRadioScope,
                          channels: [AnalyticsRadioChannel],
                          hidden: Set<RadioID>) -> AnalyticsRadioSelection {
        switch scope {
        case .all:
            return AnalyticsRadioSelection(hidden: hidden, channelRadios: nil)
        case .channel(let id):
            // A selection whose channel has vanished (its radio left) falls
            // back to every visible radio rather than showing nothing.
            return AnalyticsRadioSelection(
                hidden: hidden,
                channelRadios: channels.first { $0.id == id }?.radioIDs)
        }
    }
}

/// Which radios a scope admits.
///
/// Hidden radios are always denied. A chosen channel additionally restricts to
/// its members. A radio in neither list — one that has since disconnected but
/// whose traffic is still inside the timeframe — is admitted, so history does
/// not disappear when a radio is unplugged.
nonisolated struct AnalyticsRadioSelection: Hashable, Sendable {
    var hidden: Set<RadioID> = []
    var channelRadios: Set<RadioID>?

    /// Nothing to filter: every stored radio counts.
    static let everything = AnalyticsRadioSelection()

    var admitsEveryRadio: Bool { hidden.isEmpty && channelRadios == nil }

    func admits(_ radio: RadioID) -> Bool {
        if hidden.contains(radio) { return false }
        if let channelRadios { return channelRadios.contains(radio) }
        return true
    }
}
