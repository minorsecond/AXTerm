import Foundation

/// Other stations' movement on the map (operator, 2026-10-07): a station
/// reporting speed is drawn as an arrow along its reported course, and in
/// car mode fixed stations are drawn quieter so the mobiles stand out.
nonisolated enum StationMotion {
    /// Below this a reported speed is a parked car's GPS wander.
    static let movingKnots = 3
    /// A report of speed older than this says nothing about now.
    static let freshFor: TimeInterval = 15 * 60

    /// Degrees clockwise to turn the station's arrow on screen; nil draws
    /// its dot.
    static func arrowRotation(courseDegrees: Int?, speedKnots: Int?, lastHeard: Date?,
                              now: Date, mapHeading: Double) -> Double? {
        guard isMoving(speedKnots: speedKnots, lastHeard: lastHeard, now: now),
              let course = courseDegrees else { return nil }
        let turn = (Double(course) - mapHeading).truncatingRemainder(dividingBy: 360)
        return turn < 0 ? turn + 360 : turn
    }

    /// Reported speed worth drawing, heard recently enough to still be true.
    static func isMoving(speedKnots: Int?, lastHeard: Date?, now: Date) -> Bool {
        guard let speed = speedKnots, speed >= movingKnots, let lastHeard else { return false }
        return now.timeIntervalSince(lastHeard) <= freshFor
    }

    /// Drawn smaller and dimmer in car mode: not moving, and not a vehicle.
    static func isQuiet(symbol: APRSMapSymbol?, isNode: Bool, moving: Bool) -> Bool {
        if moving { return false }
        if isNode { return true }
        guard let symbol else { return true }
        return APRSStationClass.classify(code: symbol.code, hasMotion: false) != .moving
    }
}
