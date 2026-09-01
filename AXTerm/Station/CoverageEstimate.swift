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

    struct Ring: Equatable, Sendable {
        /// Half the stations that answered are inside this.
        var typicalKm: Double
        /// The farthest station that demonstrably decoded us.
        var reachKm: Double
        var stationCount: Int
        var farthestCallsign: String

        /// Tooltip prose: what the rings mean and where they came from.
        var summary: String { summary(inMiles: true) }

        func summary(inMiles: Bool) -> String {
            let reach = DistanceDisplay.string(kilometres: reachKm, inMiles: inMiles)
            let typical = DistanceDisplay.string(kilometres: typicalKm, inMiles: inMiles)
            return String(
                format: "Estimated coverage, measured from the %d station%@ that "
                + "answered this station directly (a UA, DM or FRMR to our frames "
                + "proves they decoded us; calls that went unanswered do not count). "
                + "Inner ring: half of them are within "
                + "%@. Outer ring: the farthest answer came from %@ at %@. "
                + "Measurements, not a propagation model — terrain will bend both.",
                stationCount, stationCount == 1 ? "" : "s",
                typical, farthestCallsign, reach)
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
}
