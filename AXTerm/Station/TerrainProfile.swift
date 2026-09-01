import Foundation

/// Where terrain elevation comes from.
///
/// Abstracted so the physics below can be tested against synthetic terrain —
/// a flat plain, a single ridge, a known summit — rather than against
/// whatever a download happened to return.
nonisolated protocol ElevationSampling: Sendable {
    /// Metres above sea level, or nil where this sampler has no data.
    ///
    /// Nil is not zero. A gap in coverage read as sea level would turn an
    /// unknown ridge into a clear path, which is the most dangerous possible
    /// way to be wrong here.
    func elevation(at point: GreatCircle.Point) -> Double?
}

/// The terrain between two stations, and whether a signal can get across it.
///
/// This is the question the app exists to answer. Measured link quality says
/// *whether* a gateway answers; this says *why* — and says it before the first
/// transmission rather than after twenty failed ones.
///
/// Two corrections separate a real answer from a straight line drawn on a map:
///
/// **Earth curvature.** Two 10-metre antennas 100 km apart cannot see each
/// other over flat ground; the planet is in the way. The bulge is applied with
/// the standard k = 4/3 effective-radius factor, which accounts for the way
/// the atmosphere refracts VHF slightly downward.
///
/// **The Fresnel zone.** A path that clears the ground by a metre is not a
/// clear path. Radio needs an ellipsoidal volume around the line to be
/// unobstructed, and intruding into it costs signal well before anything
/// physically blocks the way. This is exactly the "answers but struggles"
/// signature that shows up in the link-quality data with no explanation.
nonisolated struct TerrainProfile: Equatable, Sendable {

    /// One point along the path.
    struct Sample: Equatable, Sendable {
        var distanceMetres: Double
        var coordinate: GreatCircle.Point
        /// Straight from the elevation data.
        var groundElevation: Double
        /// Ground plus the earth's bulge at this point — what the signal
        /// actually has to clear.
        var effectiveElevation: Double
        /// Height of the straight line between the two antennas here.
        var lineHeight: Double
        /// First Fresnel zone radius at this point, in metres.
        var fresnelRadius: Double

        /// How far the line passes above the effective terrain. Negative
        /// means the terrain is in the way.
        var clearance: Double { lineHeight - effectiveElevation }

        /// Clearance as a fraction of the first Fresnel zone. The number that
        /// actually predicts whether a path works.
        var fresnelRatio: Double {
            fresnelRadius > 0 ? clearance / fresnelRadius : (clearance >= 0 ? .infinity : -.infinity)
        }
    }

    enum Verdict: Equatable, Sendable {
        /// Clear line of sight with the Fresnel zone essentially unobstructed.
        case clear(worstFresnelRatio: Double)
        /// Line of sight exists but the Fresnel zone is intruded on — expect
        /// a path that works and struggles.
        case marginal(worstFresnelRatio: Double, atMetres: Double)
        /// Terrain is above the line. No line of sight.
        case obstructed(byMetres: Double, atMetres: Double)
        /// The elevation data has gaps along this path.
        case unknown(String)
    }

    var samples: [Sample]
    var verdict: Verdict
    var totalMetres: Double
    var frequencyHz: Double
    /// Antenna heights above ground, in metres, at each end.
    var originHeight: Double
    var destinationHeight: Double

    // MARK: - Constants

    /// Effective-earth-radius factor. 4/3 is the standard temperate-climate
    /// value: the atmosphere refracts VHF slightly downward, so the radio
    /// horizon is further than the optical one.
    static let refractionFactor = 4.0 / 3.0

    /// Fraction of the first Fresnel zone that must be clear for a path to
    /// behave like a clear one. 0.6 is the long-standing engineering rule —
    /// below it, diffraction loss becomes significant.
    static let fresnelClearanceThreshold = 0.6

    /// Speed of light, for the wavelength.
    static let speedOfLight = 299_792_458.0

    /// Default sample count along a path.
    ///
    /// 256 puts samples about 400 m apart on a 100 km path, which is finer
    /// than the ridges that matter and coarse enough to stay instant. More
    /// samples cannot help beyond the resolution of the elevation data.
    static let defaultSampleCount = 256

    // MARK: - Building

    /// Computes the profile between two stations.
    ///
    /// - Parameters:
    ///   - originHeight: antenna height above ground, metres.
    ///   - frequencyHz: used for the Fresnel zone. A path that is clear at
    ///     440 MHz may be marginal at 145 MHz, because the zone is wider at
    ///     lower frequencies.
    static func between(origin: GreatCircle.Point,
                        destination: GreatCircle.Point,
                        originHeight: Double,
                        destinationHeight: Double,
                        frequencyHz: Double,
                        sampler: ElevationSampling,
                        sampleCount: Int = defaultSampleCount) -> TerrainProfile {

        let totalMetres = GreatCircle.kilometres(from: origin, to: destination) * 1000
        let points = GreatCircle.samplePath(from: origin, to: destination, count: sampleCount)

        // Both ends must be known or the line has no defined endpoints.
        guard let originGround = sampler.elevation(at: origin),
              let destinationGround = sampler.elevation(at: destination) else {
            return TerrainProfile(samples: [], verdict: .unknown(
                "No elevation data at one or both ends of this path."),
                totalMetres: totalMetres, frequencyHz: frequencyHz,
                originHeight: originHeight, destinationHeight: destinationHeight)
        }

        let originAntenna = originGround + originHeight
        let destinationAntenna = destinationGround + destinationHeight
        let wavelength = speedOfLight / max(frequencyHz, 1)

        var samples: [Sample] = []
        var missing = 0

        for (index, point) in points.enumerated() {
            let fraction = sampleCount > 1 ? Double(index) / Double(sampleCount - 1) : 0
            let d1 = totalMetres * fraction
            let d2 = totalMetres - d1

            guard let ground = sampler.elevation(at: point) else {
                missing += 1
                continue
            }

            samples.append(Sample(
                distanceMetres: d1,
                coordinate: point,
                groundElevation: ground,
                effectiveElevation: ground + earthBulge(d1: d1, d2: d2),
                lineHeight: originAntenna + (destinationAntenna - originAntenna) * fraction,
                fresnelRadius: fresnelRadius(wavelength: wavelength, d1: d1, d2: d2)))
        }

        // A path with holes in it cannot be given a verdict: the missing
        // stretch is exactly where the ridge might be.
        if missing > 0 {
            return TerrainProfile(
                samples: samples,
                verdict: .unknown("Elevation data is missing for \(missing) of \(points.count) points along this path, so no verdict is possible. Download terrain for this area."),
                totalMetres: totalMetres, frequencyHz: frequencyHz,
                originHeight: originHeight, destinationHeight: destinationHeight)
        }

        return TerrainProfile(
            samples: samples, verdict: verdict(for: samples),
            totalMetres: totalMetres, frequencyHz: frequencyHz,
            originHeight: originHeight, destinationHeight: destinationHeight)
    }

    /// The verdict, from the worst point along the path.
    ///
    /// The endpoints are excluded: the antennas sit on their own ground, so
    /// the clearance there is exactly the antenna height and the Fresnel
    /// radius is zero. Including them would report every path as obstructed
    /// by its own mast.
    static func verdict(for samples: [Sample]) -> Verdict {
        let interior = samples.dropFirst().dropLast()
        guard !interior.isEmpty else { return .clear(worstFresnelRatio: .infinity) }

        if let blocked = interior.filter({ $0.clearance < 0 })
            .min(by: { $0.clearance < $1.clearance }) {
            return .obstructed(byMetres: -blocked.clearance,
                               atMetres: blocked.distanceMetres)
        }

        guard let worst = interior.min(by: { $0.fresnelRatio < $1.fresnelRatio }) else {
            return .clear(worstFresnelRatio: .infinity)
        }

        return worst.fresnelRatio < fresnelClearanceThreshold
            ? .marginal(worstFresnelRatio: worst.fresnelRatio, atMetres: worst.distanceMetres)
            : .clear(worstFresnelRatio: worst.fresnelRatio)
    }

    // MARK: - What the obstruction costs

    /// How much signal the terrain actually takes, in decibels.
    ///
    /// Metres above the line answer "is there something in the way". They do
    /// not answer "does it matter", and the two come apart badly: 4 m above
    /// the line 1 km out costs about 7 dB, which a packet link shrugs off,
    /// while 4 m above the line at the midpoint of a 100 km path is a
    /// different number entirely. Reporting the first as "blocked" and
    /// leaving the operator to guess was the fault here.
    ///
    /// Knife-edge diffraction, ITU-R P.526. A single ridge is the case this
    /// models honestly; a long shallow rise loses more than this says, so
    /// treat it as the optimistic end.
    ///
    /// Nil when there is no verdict to have — a gap in the data is not a
    /// clear path.
    var diffractionLossDb: Double? {
        let interior = samples.dropFirst().dropLast()
        guard case .unknown = verdict else {
            guard let worst = interior.min(by: { $0.fresnelRatio < $1.fresnelRatio })
            else { return 0 }
            return Self.knifeEdgeLossDb(fresnelRatio: worst.fresnelRatio)
        }
        return nil
    }

    /// Loss for a clearance expressed as a fraction of the first Fresnel
    /// radius. Positive ratio is clearance, negative is intrusion.
    static func knifeEdgeLossDb(fresnelRatio: Double) -> Double {
        guard fresnelRatio.isFinite else { return 0 }
        // The Fresnel-Kirchhoff parameter. Falls straight out of the ratio the
        // samples already carry: v = -sqrt(2) x (clearance / F1).
        let v = -(2.0).squareRoot() * fresnelRatio
        // Below -0.78 the formula goes negative and the honest answer is zero.
        // That threshold is 0.55 of the first zone — which is why 0.6 has been
        // the engineering rule for as long as it has.
        guard v > -0.78 else { return 0 }
        let shifted = v - 0.1
        return 6.9 + 20 * log10((shifted * shifted + 1).squareRoot() + shifted)
    }

    /// How many separate stretches of the path intrude into the clearance it
    /// needs.
    ///
    /// The loss figure comes from the single worst point, which is the
    /// classic knife edge. Two ridges cost more than the worse of them —
    /// the second diffracts what the first left — so with more than one
    /// obstruction the number is a floor rather than an estimate, and saying
    /// so is the difference between a model and a guess wearing a unit.
    var obstructionCount: Int {
        var count = 0
        var inside = false
        for sample in samples.dropFirst().dropLast() {
            let intruding = sample.fresnelRatio < Self.fresnelClearanceThreshold
            if intruding, !inside { count += 1 }
            inside = intruding
        }
        return count
    }

    /// True when the reported loss understates what the path actually costs.
    var lossIsAFloor: Bool { obstructionCount > 1 }

    /// The worst sample in each separate stretch that intrudes on the
    /// clearance the path needs, in order along the path.
    ///
    /// The verdict comes from one of these, and the caption counts them, so
    /// the chart has to be able to draw all of them: saying "2 separate
    /// obstructions" while marking one leaves the operator looking for a
    /// second ridge with no idea where it is. Which one matters most is a
    /// different question from how many there are, and both are worth
    /// answering.
    var obstructions: [Sample] {
        var found: [Sample] = []
        var current: Sample?
        for sample in samples.dropFirst().dropLast() {
            if sample.fresnelRatio < Self.fresnelClearanceThreshold {
                if let running = current, running.fresnelRatio <= sample.fresnelRatio {
                    continue
                }
                current = sample
            } else if let running = current {
                found.append(running)
                current = nil
            }
        }
        if let running = current { found.append(running) }
        return found
    }

    /// What the loss figure is worth, said where the figure is.
    var lossCaveat: String? {
        guard diffractionLossDb != nil else { return nil }
        guard lossIsAFloor else { return nil }
        return "\(obstructionCount) separate obstructions — a single-edge model, "
            + "so this is the least it costs, not the most."
    }

    /// What the loss means for a packet link, which is the question actually
    /// being asked.
    ///
    /// Bands rather than a bare number: an operator deciding whether to try a
    /// station needs "will this work", and decibels only answer that against
    /// a link budget they would have to keep in their head.
    enum Severity: Equatable, Sendable {
        /// Under 3 dB. Half an S-unit, inside the day-to-day variation of any
        /// real path.
        case negligible
        /// 3-10 dB. Real, and the difference between a solid link and one that
        /// retries, but not the difference between working and not.
        case noticeable
        /// 10-20 dB. Usually decisive at the powers and antennas packet runs.
        case severe
        /// Over 20 dB. Gone, and no amount of power on this path fixes it.
        case blocking
        /// No terrain data.
        case unknown
    }

    var severity: Severity {
        guard let loss = diffractionLossDb else { return .unknown }
        switch loss {
        case ..<3: return .negligible
        case ..<10: return .noticeable
        case ..<20: return .severe
        default: return .blocking
        }
    }

    /// The headline, in the terms that decide whether to call the station.
    ///
    /// Leads with the consequence rather than the geometry. "Blocked by 4 m"
    /// was true and useless — it named a measurement, in a unit that does not
    /// answer the question, at a precision the assumed antenna heights do not
    /// support.
    var headline: String {
        guard let loss = diffractionLossDb else { return "No terrain data" }
        let decibels = "\(Int(loss.rounded())) dB"
        switch severity {
        case .negligible:
            return loss < 0.5 ? "Clear path" : "Clear \u{2014} terrain costs about \(decibels)"
        case .noticeable:
            return "Workable \u{2014} terrain costs about \(decibels)"
        case .severe:
            return "Marginal \u{2014} terrain costs about \(decibels)"
        case .blocking:
            return "Blocked \u{2014} terrain costs about \(decibels)"
        case .unknown:
            return "No terrain data"
        }
    }

    /// Where the obstruction is and how far it reaches above the line, for
    /// the line under the headline. The geometry is still worth stating: it
    /// is what an antenna change acts on.
    var geometryNote: String? {
        switch verdict {
        case .obstructed(let by, let at):
            return "Terrain \(Int(by.rounded())) m above the line, "
                + "\(Verdict.distanceText(at)) out"
        case .marginal(_, let at):
            return "Closest approach \(Verdict.distanceText(at)) out"
        case .clear, .unknown:
            return nil
        }
    }

    // MARK: - Physics

    /// How far the earth bulges above the chord between two points, at a
    /// point `d1` from one end and `d2` from the other.
    ///
    /// This is what makes a 100 km path over flat ground impossible for two
    /// low antennas, and leaving it out is the single most common way a
    /// path-profile tool lies.
    static func earthBulge(d1: Double, d2: Double) -> Double {
        guard d1 > 0, d2 > 0 else { return 0 }
        return (d1 * d2) / (2 * refractionFactor * GreatCircle.earthRadiusMetres)
    }

    /// First Fresnel zone radius, metres.
    static func fresnelRadius(wavelength: Double, d1: Double, d2: Double) -> Double {
        let total = d1 + d2
        guard total > 0, d1 > 0, d2 > 0 else { return 0 }
        return sqrt(wavelength * d1 * d2 / total)
    }

    /// Radio horizon distance in kilometres for an antenna at `heightMetres`,
    /// with the 4/3 refraction factor. The familiar 4.12 × √h.
    static func radioHorizonKilometres(heightMetres: Double) -> Double {
        guard heightMetres > 0 else { return 0 }
        return sqrt(2 * refractionFactor * GreatCircle.earthRadiusMetres * heightMetres) / 1000
    }
}

// MARK: - Explaining

extension TerrainProfile.Verdict {

    var isUsable: Bool {
        switch self {
        case .clear: true
        case .marginal, .obstructed, .unknown: false
        }
    }

    var summary: String {
        switch self {
        case .clear:
            "Clear path"
        case .marginal:
            "Marginal — Fresnel zone obstructed"
        case .obstructed(let by, let at):
            // Where, not only how much. "Blocked by 4 m" on a 43 km path
            // reads as a wall; the same 4 m a kilometre from the operator's
            // own mast is an afternoon with a ladder, and the distance is
            // what tells those apart.
            "Blocked by \(Int(by.rounded())) m \(Self.distanceText(at)) out"
        case .unknown:
            "No terrain data"
        }
    }

    /// The full account, in the terms that decide what to do about it.
    func explanation(profile: TerrainProfile) -> String {
        let band = Self.frequencyText(profile.frequencyHz)
        switch self {
        case .clear(let ratio):
            let clearance = ratio.isFinite ? String(format: "%.1f×", ratio) : "fully"
            return """
            Line of sight is clear, and the first Fresnel zone is \(clearance) clear at its worst point.

            Terrain is not what is limiting this path at \(band). If the gateway does not answer, look elsewhere — wrong frequency, station off the air, or a receiver problem at one end.
            """

        case .marginal(let ratio, let at):
            return """
            There is line of sight, but the first Fresnel zone is only \(String(format: "%.0f%%", ratio * 100)) clear at \(Self.distanceText(at)) along the path — below the 60% that behaves like a clear path.

            Expect a link that connects and struggles: retries, slow throughput, and a station that answers sometimes. That is a terrain-limited path, not a broken one.

            Raising either antenna helps most; the obstruction is near \(Self.distanceText(at)) out, so height at the closer end has more effect.
            """

        case .obstructed(let by, let at):
            return """
            Terrain rises \(Int(by.rounded())) m above the line between the two antennas, \(Self.distanceText(at)) along the path. There is no line of sight at \(band).

            A direct contact is unlikely regardless of power. Use a digipeater or a gateway with a path around the obstruction — the map shows which stations you have actually worked from here.

            Raising an antenna by \(Int(by.rounded())) m or more would clear it geometrically, which is usually impractical but tells you the scale of the problem.
            """

        case .unknown(let reason):
            return reason
        }
    }

    static func distanceText(_ metres: Double) -> String {
        metres >= 1000
            ? String(format: "%.1f km", metres / 1000)
            : String(format: "%.0f m", metres)
    }

    private static func frequencyText(_ hertz: Double) -> String {
        hertz > 0 ? String(format: "%.3f MHz", hertz / 1_000_000) : "this frequency"
    }
}
