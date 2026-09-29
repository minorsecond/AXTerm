import Foundation

/// Whether a station could plausibly have been heard over the air.
///
/// Packet networks are bridged. A local node linked to the internet — LinBPQ,
/// a Winlink CMS gateway, an APRS-IS feed — puts frames from stations
/// thousands of kilometres away onto the same stream as the neighbour down
/// the road, and nothing in a frame distinguishes them. The result is a
/// station list where a Maryland node sits between two Denver ones.
///
/// This does not delete anything and does not decide anything for the
/// operator. It marks what could not have arrived by radio, so a toggle can
/// put those aside — the local picture is what an operator is usually
/// reading, and one distant station also stretches the map's zoom until
/// everything real is a cluster of dots.
nonisolated enum StationPlausibility {

    enum Verdict: Equatable, Sendable {
        /// Within radio range, or near enough that the question is open.
        case plausible
        /// Too far to have arrived by radio on these bands.
        case beyondRadioRange(kilometres: Double)
        /// No position, so there is nothing to judge. Never hidden: an
        /// unplaced station is usually the one most worth looking at.
        case unknown

        var isImplausible: Bool {
            if case .beyondRadioRange = self { return true }
            return false
        }
    }

    /// Beyond this, a VHF/UHF packet path is not a path.
    ///
    /// Deliberately generous. Real terrestrial packet links run to a couple
    /// hundred kilometres from good sites, and tropospheric ducting can carry
    /// a signal further on a lucky evening. Three hundred kilometres is well
    /// past anything routine and nowhere near the two thousand that says
    /// "this came down a wire" — the point is to catch the obvious cases
    /// without ever quietly hiding a genuine long haul.
    static let defaultRangeKilometres: Double = 300

    /// Judges one station.
    ///
    /// - Parameters:
    ///   - confidence: what the position actually describes. A position
    ///     inferred from a *different* entity — a node alias placed at its
    ///     operator's licence address — is never called implausible. A node
    ///     sitting on a Colorado hilltop whose licensee lives in Virginia is
    ///     a real and common thing, and hiding it would remove a station that
    ///     is genuinely on the air here. The distance would be measuring the
    ///     operator's mailing address, not the radio.
    static func verdict(observer: GreatCircle.Point?,
                        station: GreatCircle.Point?,
                        confidence: HeardStationMap.PositionConfidence,
                        rangeKilometres: Double = defaultRangeKilometres) -> Verdict {
        guard let observer, let station else { return .unknown }
        guard confidence > .inferredFromOperator else { return .plausible }

        let distance = GreatCircle.kilometres(from: observer, to: station)
        return distance > rangeKilometres ? .beyondRadioRange(kilometres: distance)
                                          : .plausible
    }

    /// How to describe where a position came from, given what the geometry
    /// says about it.
    ///
    /// The card used to state "APRS position (heard over the air)" for every
    /// transmitted fix — including stations this same type had already set
    /// aside as too far to have been heard. KC0AUH-2, 394 km away, was
    /// counted in the sidebar's "4 too far to have been heard" while its own
    /// card asserted the opposite. The app knew; the sentence did not.
    ///
    /// The claim is therefore made only when it holds. Beyond range the line
    /// says what is certain — the distance — and stops short of naming a
    /// mechanism: a relay, an igate, or a genuinely exceptional path are all
    /// possible, and the frame does not say which. `APRSFrameOrigin` answers
    /// that separately, from what the frame states outright.
    static func positionSourceLine(source: String,
                                   verdict: Verdict,
                                   inMiles: Bool = false) -> String {
        switch verdict {
        case .plausible, .unknown:
            return "Position from \(source) (heard over the air)."
        case .beyondRadioRange(let kilometres):
            // States the distance and the rule, not the physics. Whether a
            // path is possible depends on both stations' altitude, the
            // terrain between them and the day's propagation — a mountaintop
            // digipeater works stations a flat threshold calls impossible.
            // The map needs a cutoff to keep one far station from stretching
            // the zoom; that cutoff is a display rule, and saying so is
            // honest where "beyond radio range" would be a claim we cannot
            // back with what the frame carries.
            let distance = DistanceDisplay.string(kilometres: kilometres, inMiles: inMiles)
            let limit = DistanceDisplay.string(kilometres: defaultRangeKilometres,
                                               inMiles: inMiles)
            return "Position from \(source). At \(distance) it is further than the "
                 + "\(limit) this map treats as directly hearable."
        }
    }

    /// Splits entries into what to show and what to set aside.
    ///
    /// Returns both halves rather than filtering in place, because the count
    /// of what was hidden has to be shown. A list that silently drops rows is
    /// how twenty missing stations stay missing.
    static func partition(_ entries: [HeardStationMap.Entry],
                          observer: GreatCircle.Point?,
                          rangeKilometres: Double = defaultRangeKilometres)
        -> (shown: [HeardStationMap.Entry], hidden: [HeardStationMap.Entry]) {
        var shown: [HeardStationMap.Entry] = []
        var hidden: [HeardStationMap.Entry] = []
        for entry in entries {
            let verdict = verdict(observer: observer,
                                  station: entry.position,
                                  confidence: entry.confidence,
                                  rangeKilometres: rangeKilometres)
            if verdict.isImplausible { hidden.append(entry) } else { shown.append(entry) }
        }
        return (shown, hidden)
    }
}
