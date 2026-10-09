import Foundation

/// How a movement trail is drawn (operator, 2026-10-09: "make the trails
/// really useful and aesthetic").
///
/// - In its station's marker color, so whose trail it is reads at a glance;
///   recency is opacity, as on the markers.
/// - Fading by time from faint at the oldest fix to full strength at the
///   newest, so the trail shows which way the station went and which end is
///   now.
/// - Dashed and fainter between fixes more than `gapSeconds` apart: there
///   the straight line is a guess, not the road.
/// - The selected station's trail thicker and at full strength with each fix
///   marked; the others dimmed while it is selected.
nonisolated enum TrailPlan {

    enum Emphasis: Equatable, Sendable { case normal, selected, dimmed }

    struct Piece: Equatable, Sendable {
        let points: [GreatCircle.Point]
        /// Opacity at the piece's first and last point; drawn as a gradient.
        let startAlpha: Double
        let endAlpha: Double
        let width: Double
        let dashed: Bool
    }

    struct Plan: Equatable, Sendable {
        var pieces: [Piece] = []
        /// Beacon fixes to mark with a dot: the selected station's only.
        var fixes: [GreatCircle.Point] = []
    }

    /// Fixes further apart than this are joined by a dashed guess.
    static let gapSeconds: TimeInterval = 10 * 60
    /// The oldest end's share of full strength.
    static let tailFloor = 0.15
    /// A dashed stretch is drawn this much fainter than the fade at that point.
    static let gapAlphaFactor = 0.6
    static let dimFactor = 0.3

    static func plan(points: [GreatCircle.Point], times: [Date], emphasis: Emphasis,
                     baseAlpha: Double) -> Plan {
        guard points.count >= 2 else { return Plan() }
        let top: Double
        let width: Double
        switch emphasis {
        case .selected: top = 1; width = 4.5
        case .normal: top = baseAlpha; width = 3
        case .dimmed: top = baseAlpha * dimFactor; width = 2
        }
        let fractions = fadeFractions(count: points.count, times: times)
        func alpha(_ index: Int) -> Double { top * (tailFloor + (1 - tailFloor) * fractions[index]) }

        var plan = Plan()
        var run: [Int] = [0]
        func closeRun() {
            guard run.count >= 2, let first = run.first, let last = run.last else { return }
            plan.pieces.append(Piece(points: run.map { points[$0] }, startAlpha: alpha(first),
                                     endAlpha: alpha(last), width: width, dashed: false))
        }
        for index in 1..<points.count {
            let isGap = times.count == points.count
                && times[index].timeIntervalSince(times[index - 1]) > gapSeconds
            if isGap {
                closeRun()
                plan.pieces.append(Piece(points: [points[index - 1], points[index]],
                                         startAlpha: alpha(index - 1) * gapAlphaFactor,
                                         endAlpha: alpha(index) * gapAlphaFactor,
                                         width: width * 0.75, dashed: true))
                run = [index]
            } else {
                run.append(index)
            }
        }
        closeRun()
        if emphasis == .selected { plan.fixes = points }
        return plan
    }

    /// Recency as opacity, the same steps the markers use.
    static func baseAlpha(for signal: StationScope.Signal) -> Double {
        switch signal {
        case .good: return 1
        case .fair: return 0.9
        case .poor: return 0.6
        case .unknown: return 0.45
        }
    }

    static func emphasis(for id: String, selection: String?) -> Emphasis {
        guard let selection else { return .normal }
        return selection.caseInsensitiveCompare(id) == .orderedSame ? .selected : .dimmed
    }

    /// Where each fix sits between the oldest (0) and the newest (1), by
    /// time when the times are known, by position otherwise.
    private static func fadeFractions(count: Int, times: [Date]) -> [Double] {
        if times.count == count, let first = times.first, let last = times.last, last > first {
            let span = last.timeIntervalSince(first)
            return times.map { $0.timeIntervalSince(first) / span }
        }
        return (0..<count).map { Double($0) / Double(count - 1) }
    }
}
