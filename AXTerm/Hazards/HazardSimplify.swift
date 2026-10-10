import Foundation

/// Outlines thinned for drawing (Douglas-Peucker). NWS coastal zone
/// outlines run to 8,000 points each; 191 cached Florida and Georgia zones
/// held 140,000, all copied, compared and drawn on every update, and iOS
/// lagged while alerts loaded (2026-10-09).
nonisolated enum HazardSimplify {
    /// About 50 m: finer than any screen shows a county or zone.
    static let drawingTolerance = 0.0005

    /// A closed ring with the points that change its shape by less than
    /// `tolerance` degrees removed. Never fewer than four points.
    static func ring(_ ring: [GreatCircle.Point], tolerance: Double) -> [GreatCircle.Point] {
        guard ring.count > 4 else { return ring }
        let closed = ring.first == ring.last
        let open = closed ? Array(ring.dropLast()) : ring
        guard open.count > 3 else { return ring }
        // Split at the point farthest from the first, then thin each half.
        let scale = cos(open[0].latitude * .pi / 180)
        let far = (1..<open.count).max { distance(open[0], open[$0], scale) < distance(open[0], open[$1], scale) } ?? 1
        let first = line(Array(open[0...far]), tolerance: tolerance, scale: scale)
        let second = line(Array(open[far...]) + [open[0]], tolerance: tolerance, scale: scale)
        var result = first + second.dropFirst()   // second ends at open[0]: the ring closes
        if !closed { result.removeLast() }
        return result.count >= 4 ? result : ring
    }

    /// An open line thinned, keeping its two ends.
    private static func line(_ points: [GreatCircle.Point], tolerance: Double, scale: Double) -> [GreatCircle.Point] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var worst = 0.0
            var index = a
            for i in (a + 1)..<b {
                let d = offset(points[i], from: points[a], to: points[b], scale)
                if d > worst { worst = d; index = i }
            }
            if worst > tolerance {
                keep[index] = true
                stack.append((a, index))
                stack.append((index, b))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    private static func distance(_ a: GreatCircle.Point, _ b: GreatCircle.Point, _ scale: Double) -> Double {
        let dx = (b.longitude - a.longitude) * scale, dy = b.latitude - a.latitude
        return (dx * dx + dy * dy).squareRoot()
    }

    /// How far `p` lies from the segment a–b, in degrees of latitude.
    private static func offset(_ p: GreatCircle.Point, from a: GreatCircle.Point, to b: GreatCircle.Point,
                               _ scale: Double) -> Double {
        let ax = a.longitude * scale, ay = a.latitude
        let bx = b.longitude * scale, by = b.latitude
        let px = p.longitude * scale, py = p.latitude
        let dx = bx - ax, dy = by - ay
        let length = dx * dx + dy * dy
        guard length > 0 else { return ((px - ax) * (px - ax) + (py - ay) * (py - ay)).squareRoot() }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / length))
        let cx = ax + t * dx, cy = ay + t * dy
        return ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
    }
}
