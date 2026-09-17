//
//  CoverageEstimate.swift
//  AXTerm
//
//  How far this station's signal demonstrably reaches, inferred from who
//  answered it.
//
//  Coverage is not "who I can hear" — a well-sited node is heard fifty
//  miles past the range of a home station's own transmitter. The honest
//  evidence is the reverse direction: a station that *answered us* (a UA to
//  our SABM, a DM or FRMR to our ping, a completed session) necessarily
//  decoded our transmission. Each such station with a known position is a
//  measured point inside our footprint.
//
//  Which is why nothing weaker than an answer counts. Our own transmissions
//  come back through the receive path, so every station we have ever called
//  has a direct path to us at `.heardDirect` whether or not it ever replied.
//  Counting those plotted stations we shouted at and never reached as
//  measured coverage — and since the outer ring is the farthest of them, one
//  unanswered call to a distant node set the whole reach figure.
//
//  Two rings, because one number would lie in one direction or the other:
//  the median answered distance is where the signal reliably works; the
//  farthest is the best it has ever demonstrably done. Neither is a
//  propagation model — both are measurements, which is why they belong on
//  the map at all.
//

import Foundation

nonisolated enum CoverageEstimate {

    /// Evidence newer than this counts. Propagation shifts with seasons
    /// and antennas with ladders; a UA from last month proves last month.
    static let evidenceWindow: TimeInterval = 14 * 24 * 3600

    /// What proved the far end decoded us.
    ///
    /// The two modes leave different evidence and the difference is not
    /// cosmetic. Connected mode needs someone willing to answer, so the ring
    /// only grows where the operator went looking. A digipeat arrives unasked
    /// with every beacon, so the APRS ring fills in on its own and says more
    /// about where our signal lands than about who will talk to us.
    ///
    /// Kept apart rather than pooled: one ring built from both would answer
    /// neither question.
    enum Evidence: Equatable, Sendable {
        /// A UA, DM or FRMR to our frames: the far end decoded us and said so.
        case answered
        /// A digipeater put one of our own frames back on the air. Proof it
        /// decoded the frame, and the only evidence that costs the operator
        /// nothing to collect.
        case digipeated
        /// A frame of theirs reached us with nothing between: their
        /// transmitter to our receiver. The other direction, and usually the
        /// longer one — a hilltop digipeater is heard from well outside the
        /// range of the home station listening to it.
        case heardDirect

        /// Which way the signal travelled. The two directions are different
        /// distances and a ring that did not say which it measured would be
        /// read as the other one.
        var isTransmit: Bool { self != .heardDirect }
    }

    struct Ring: Equatable, Sendable {
        /// Half the stations that answered are inside this.
        var typicalKm: Double
        /// The farthest station that demonstrably decoded us.
        var reachKm: Double
        var stationCount: Int
        var farthestCallsign: String
        var evidence: Evidence = .answered

        /// Tooltip prose: what the rings mean and where they came from.
        var summary: String { summary(inMiles: true) }

        func summary(inMiles: Bool) -> String {
            let reach = DistanceDisplay.string(kilometres: reachKm, inMiles: inMiles)
            let typical = DistanceDisplay.string(kilometres: typicalKm, inMiles: inMiles)
            let source: String
            switch evidence {
            case .answered:
                source = String(
                    format: "measured from the %d station%@ that answered this station "
                    + "directly (a UA, DM or FRMR to our frames proves they decoded us; "
                    + "calls that went unanswered do not count)",
                    stationCount, stationCount == 1 ? "" : "s")
            case .digipeated:
                source = String(
                    format: "measured from the %d digipeater%@ that put our own frames back "
                    + "on the air (repeating a frame proves it decoded the frame; a station "
                    + "that only heard us relayed by somebody else does not count)",
                    stationCount, stationCount == 1 ? "" : "s")
            case .heardDirect:
                source = String(
                    format: "measured from the %d station%@ we decoded with no digipeater in "
                    + "the path (a repeated frame proves the digipeater reached us and says "
                    + "nothing about who sent it, so it does not count)",
                    stationCount, stationCount == 1 ? "" : "s")
            }
            let farthestLabel: String
            switch evidence {
            case .answered: farthestLabel = "answer"
            case .digipeated: farthestLabel = "repeat"
            case .heardDirect: farthestLabel = "decode"
            }
            return String(
                format: "%@, %@. Inner ring: half of them are within %@. "
                + "Outer ring: the farthest %@ came from %@ at %@. Measurements, not a "
                + "propagation model \u{2014} terrain will bend both.",
                evidence.isTransmit ? "Estimated coverage" : "Estimated receive range",
                source, typical,
                farthestLabel,
                farthestCallsign, reach)
        }
    }

    /// Builds the ring from observed paths.
    ///
    /// A path counts when it touches one of our own addresses (full
    /// callsign match — a base-callsign match would count a node's
    /// borrowed relay leg, whose transmitter is the node's, not ours),
    /// travelled direct (a digipeated answer proves the digipeater's
    /// coverage, not ours), is fresh, and reached `.sessionEstablished` —
    /// a connect request answered, so frames crossed in both directions.
    /// That last is the only level that proves the far end decoded us
    /// rather than merely that we transmitted at it.
    static func ring(paths: [NetworkPath],
                     ownAddresses: [String],
                     positions: [String: GreatCircle.Point],
                     observer: GreatCircle.Point,
                     now: Date = Date()) -> Ring? {
        let ours = Set(ownAddresses.map { $0.trimmingCharacters(in: .whitespaces).uppercased() })
        guard !ours.isEmpty else { return nil }
        let cutoff = now.addingTimeInterval(-evidenceWindow)

        var distances: [(callsign: String, km: Double)] = []
        var seen = Set<String>()
        for path in paths {
            guard path.via.isEmpty,
                  path.evidence >= .sessionEstablished,
                  path.lastSeen >= cutoff else { continue }
            let from = path.from.uppercased()
            let to = path.to.uppercased()
            let counterpart: String
            if ours.contains(from), !ours.contains(to) {
                counterpart = to
            } else if ours.contains(to), !ours.contains(from) {
                counterpart = from
            } else {
                continue
            }
            guard !seen.contains(counterpart),
                  let position = positions[counterpart] else { continue }
            seen.insert(counterpart)
            distances.append((counterpart, GreatCircle.kilometres(from: observer, to: position)))
        }

        guard !distances.isEmpty else { return nil }
        let sorted = distances.sorted { $0.km < $1.km }
        let farthest = sorted[sorted.count - 1]
        let median = sorted[(sorted.count - 1) / 2].km
        return Ring(
            typicalKm: median,
            reachKm: farthest.km,
            stationCount: sorted.count,
            farthestCallsign: farthest.callsign)
    }

    /// Coverage from APRS evidence: who put our own frames back on the air.
    ///
    /// The connected-mode ring above refuses digipeated evidence, and is
    /// right to: an answer that arrived through a digipeater proves the
    /// digipeater's coverage rather than ours. Here the digipeater *is* the
    /// measurement. It heard our beacon and repeated it, so it decoded us,
    /// and its position is a point inside our footprint by the same standard
    /// the other ring applies to a UA.
    ///
    /// It also fills in on its own. The other ring only grows where the
    /// operator went looking for someone to talk to; this one arrives with
    /// every beacon whether anyone is listening or not.
    ///
    /// Nothing weaker counts. A station that merely transmitted soon after
    /// we did is `likely`, not proof, and the tracker that grades it says so
    /// — pooling that in here would be the overclaiming both it and this
    /// file exist to avoid.
    static func digipeatRing(repeaters: [String: Date],
                             positions: [String: GreatCircle.Point],
                             observer: GreatCircle.Point,
                             now: Date = Date()) -> Ring? {
        ring(from: repeaters, evidence: .digipeated, positions: positions,
             observer: observer, now: now)
    }

    /// The receive ring: how far this station can hear, from the stations it
    /// decoded with nothing in between.
    ///
    /// The other direction entirely, and it is the one that fills in fastest,
    /// because every station on the channel contributes to it whether or not
    /// it has ever heard us.
    static func receiveRing(heardDirect: [String: Date],
                            positions: [String: GreatCircle.Point],
                            observer: GreatCircle.Point,
                            now: Date = Date()) -> Ring? {
        ring(from: heardDirect, evidence: .heardDirect, positions: positions,
             observer: observer, now: now)
    }

    /// Shared arithmetic for the rings built from "who, and when last".
    private static func ring(from sightings: [String: Date],
                             evidence: Evidence,
                             positions: [String: GreatCircle.Point],
                             observer: GreatCircle.Point,
                             now: Date) -> Ring? {
        let cutoff = now.addingTimeInterval(-evidenceWindow)
        var distances: [(callsign: String, km: Double)] = []
        for (callsign, at) in sightings {
            let call = callsign.trimmingCharacters(in: .whitespaces).uppercased()
            guard at >= cutoff, !call.isEmpty, let position = positions[call] else { continue }
            distances.append((call, GreatCircle.kilometres(from: observer, to: position)))
        }

        guard !distances.isEmpty else { return nil }
        let sorted = distances.sorted { $0.km < $1.km }
        let farthest = sorted[sorted.count - 1]
        return Ring(
            typicalKm: sorted[(sorted.count - 1) / 2].km,
            reachKm: farthest.km,
            stationCount: sorted.count,
            farthestCallsign: farthest.callsign,
            evidence: evidence)
    }
}

/// Which coverage rings the map draws, and in what order.
///
/// The two rings measure different things and are collected differently, so
/// the operator chooses them separately: a station with both radios can show
/// the connected-mode footprint, the APRS one, both, or neither. Drawn
/// together they have to be told apart, which is why evidence travels with
/// each ring rather than being inferred from its position in the list.
nonisolated enum CoverageRingSelection {

    /// The rings to draw, answered first so the connected-mode ring keeps the
    /// colour it has always had when it is the only one on the map.
    ///
    /// Order is fixed rather than following which is larger: a ring that
    /// changed colour when the other one grew past it would be unreadable.
    static func rings(answered: CoverageEstimate.Ring?,
                      showsAnswered: Bool,
                      digipeated: CoverageEstimate.Ring?,
                      showsDigipeated: Bool,
                      received: [CoverageEstimate.Ring] = [],
                      showsReceived: Bool = false) -> [CoverageEstimate.Ring] {
        var rings: [CoverageEstimate.Ring] = []
        if showsAnswered, let answered { rings.append(answered) }
        if showsDigipeated, let digipeated { rings.append(digipeated) }
        // The receive rings last, so a transmit ring keeps its colour and its
        // place whatever the other direction is doing.
        if showsReceived { rings.append(contentsOf: received) }
        return rings
    }
}
